/**
 * Base class for every outbound integration in the framework.
 *
 * Subclasses describe what to call (integration name, base endpoint, how to authenticate).
 * This class owns how the call is made:
 *  - Callout execution: builds the HttpRequest, sends it and wraps the result.
 *  - Auth: fetches, caches and applies access tokens; refreshes once on HTTP 401.
 *  - Timeouts: per-callout timeout, clamped to the callout time left in the transaction.
 *  - Rate limiting: optional per-transaction callout cap, governor limit checks, and HTTP 429
 *    handling (Retry-After is honoured for the rest of the transaction).
 *  - Retries: connection errors and retryable status codes (408, 5xx) on idempotent requests.
 *
 * Apex cannot sleep, so retries happen immediately within the transaction. When a delay is
 * required (HTTP 429) a RateLimitException is thrown carrying retryAfterSeconds, so the caller
 * can defer the work, e.g. by enqueueing a Queueable with a delay.
 *
 * Callouts cannot follow uncommitted DML in the same transaction; perform DML (such as logging)
 * after all callouts are complete.
 */
public abstract inherited sharing class BaseIntegrationHandler {
  private static final Integer MAX_TRANSACTION_CALLOUT_MS = 120000;
  private static final Integer MIN_CALLOUT_TIMEOUT_MS = 1000;
  private static final Integer TOKEN_EXPIRY_BUFFER_SECONDS = 60;
  private static final Set<String> IDEMPOTENT_METHODS = new Set<String>{
    'GET',
    'HEAD',
    'OPTIONS',
    'PUT',
    'DELETE'
  };

  // Transaction-scoped state shared by all handler instances, keyed by integration name.
  private static Map<String, AccessToken> accessTokens = new Map<String, AccessToken>();
  private static Map<String, Integer> calloutCounts = new Map<String, Integer>();
  private static Map<String, Datetime> rateLimitedUntil = new Map<String, Datetime>();
  private static Long totalCalloutMs = 0;

  private IntegrationHttpClient httpClient = new NativeHttpClient();

  /** Replaces the transport, e.g. with an fflib_ApexMocks mock in unit tests. */
  public void setHttpClient(IntegrationHttpClient httpClient) {
    this.httpClient = httpClient;
  }

  // ---------------------------------------------------------------------------
  // Configuration
  // ---------------------------------------------------------------------------

  /** Unique name of the integration, used to scope token caching and rate limiting. */
  protected abstract String getIntegrationName();

  /** Base endpoint, preferably a Named Credential, e.g. 'callout:Billing_API'. */
  protected abstract String getBaseEndpoint();

  /** Timeout for a single callout attempt, in milliseconds (max 120000). */
  protected virtual Integer getTimeoutMs() {
    return 30000;
  }

  /** Number of retries after the first attempt for transient failures. */
  protected virtual Integer getMaxRetries() {
    return 2;
  }

  /** Maximum callouts this integration may make per transaction, or null for no cap. */
  protected virtual Integer getMaxCalloutsPerTransaction() {
    return null;
  }

  /** Wait applied after HTTP 429 when the response has no usable Retry-After header. */
  protected virtual Integer getDefaultRetryAfterSeconds() {
    return 60;
  }

  protected virtual Set<Integer> getRetryableStatusCodes() {
    return new Set<Integer>{ 408, 500, 502, 503, 504 };
  }

  /** Headers sent with every request; request-level headers take precedence. */
  protected virtual Map<String, String> getDefaultHeaders() {
    return new Map<String, String>{
      'Accept' => 'application/json',
      'Content-Type' => 'application/json'
    };
  }

  // ---------------------------------------------------------------------------
  // Authentication
  // ---------------------------------------------------------------------------

  /**
   * Fetches a new access token from the provider. Returns null by default, meaning
   * authentication is handled elsewhere (e.g. by a Named Credential). Implementations
   * should make their token callout through send() so it is counted against the budgets.
   */
  protected virtual AccessToken requestAccessToken() {
    return null;
  }

  protected virtual void applyAccessToken(
    HttpRequest httpRequest,
    AccessToken token
  ) {
    httpRequest.setHeader('Authorization', token.tokenType + ' ' + token.value);
  }

  /**
   * Token storage. Defaults to the current transaction; override these three methods
   * to persist tokens across transactions, e.g. in Platform Cache.
   */
  protected virtual AccessToken getCachedAccessToken() {
    return accessTokens.get(getIntegrationName());
  }

  protected virtual void cacheAccessToken(AccessToken token) {
    accessTokens.put(getIntegrationName(), token);
  }

  protected virtual void clearCachedAccessToken() {
    accessTokens.remove(getIntegrationName());
  }

  // ---------------------------------------------------------------------------
  // Hooks
  // ---------------------------------------------------------------------------

  /**
   * Called after every callout attempt, including token requests. httpResponse is null and
   * error is set when no response was received. Must not perform DML.
   */
  protected virtual void onCalloutComplete(
    HttpRequest httpRequest,
    HttpResponse httpResponse,
    Exception error,
    Long durationMs
  ) {
  }

  // ---------------------------------------------------------------------------
  // Execution
  // ---------------------------------------------------------------------------

  /**
   * Executes the request with auth, retries and limit enforcement.
   *
   * Returns the final response for any HTTP status other than 429, including error statuses
   * once retries are exhausted; check IntegrationResponse.isSuccess().
   *
   * @throws RateLimitException when the API answers 429 or is still rate limited from an
   *         earlier call in this transaction.
   * @throws CalloutLimitException when a governor, per-integration or callout time budget is spent.
   * @throws AuthenticationException when a valid access token cannot be obtained.
   * @throws IntegrationException when no response is received after all retries.
   */
  public IntegrationResponse execute(IntegrationRequest request) {
    if (request == null) {
      throw new IntegrationException('Request is required');
    }
    Integer maxRetries = Math.max(0, getMaxRetries() ?? 0);
    Boolean retryable = request.isRetryable();
    Boolean tokenRefreshed = false;
    Integer retries = 0;
    Integer attempts = 0;
    Long startedAt = System.currentTimeMillis();
    IntegrationResponse result;

    while (result == null) {
      attempts++;
      HttpRequest httpRequest = buildHttpRequest(request);
      AccessToken token = getAccessToken();
      if (token != null) {
        applyAccessToken(httpRequest, token);
      }

      HttpResponse httpResponse;
      try {
        httpResponse = send(httpRequest, request.timeoutMs);
      } catch (CalloutException e) {
        if (retryable && retries < maxRetries) {
          retries++;
          continue;
        }
        throw new IntegrationException(
          getIntegrationName() +
            ' callout failed after ' +
            attempts +
            ' attempt(s): ' +
            e.getMessage(),
          e
        );
      }

      Integer statusCode = httpResponse.getStatusCode();
      if (statusCode == 401 && token != null && !tokenRefreshed) {
        tokenRefreshed = true;
        clearCachedAccessToken();
        continue;
      }
      if (statusCode == 429) {
        throw blockForRateLimit(httpResponse);
      }
      if (
        retryable &&
        retries < maxRetries &&
        getRetryableStatusCodes().contains(statusCode)
      ) {
        retries++;
        continue;
      }
      result = new IntegrationResponse(
        httpResponse,
        attempts,
        System.currentTimeMillis() - startedAt,
        retryable && getRetryableStatusCodes().contains(statusCode)
      );
    }
    return result;
  }

  /**
   * Performs a single callout after checking the rate limit, per-integration cap, governor
   * callout limit and remaining callout time. No retries or auth are applied here.
   */
  protected HttpResponse send(HttpRequest httpRequest) {
    return send(httpRequest, null);
  }

  protected HttpResponse send(HttpRequest httpRequest, Integer timeoutMs) {
    String integrationName = getIntegrationName();

    Datetime blockedUntil = rateLimitedUntil.get(integrationName);
    if (blockedUntil != null && blockedUntil > Datetime.now()) {
      Long waitMs = blockedUntil.getTime() - Datetime.now().getTime();
      throw newRateLimitException((waitMs / 1000).intValue() + 1);
    }
    if (Limits.getCallouts() >= Limits.getLimitCallouts()) {
      throw new CalloutLimitException(
        'Transaction callout limit of ' + Limits.getLimitCallouts() + ' reached'
      );
    }
    Integer calloutCount = calloutCounts.get(integrationName) ?? 0;
    Integer maxCallouts = getMaxCalloutsPerTransaction();
    if (maxCallouts != null && calloutCount >= maxCallouts) {
      throw new CalloutLimitException(
        integrationName +
          ' reached its limit of ' +
          maxCallouts +
          ' callouts per transaction'
      );
    }
    Long remainingMs = MAX_TRANSACTION_CALLOUT_MS - totalCalloutMs;
    if (remainingMs < MIN_CALLOUT_TIMEOUT_MS) {
      throw new CalloutLimitException(
        'Not enough callout time left in this transaction'
      );
    }

    Integer requestedTimeoutMs = Math.max(
      timeoutMs ?? getTimeoutMs(),
      MIN_CALLOUT_TIMEOUT_MS
    );
    httpRequest.setTimeout(
      Math.min((Long) requestedTimeoutMs, remainingMs).intValue()
    );
    calloutCounts.put(integrationName, calloutCount + 1);

    Long startedAt = System.currentTimeMillis();
    HttpResponse httpResponse;
    CalloutException error;
    try {
      httpResponse = httpClient.send(httpRequest);
    } catch (CalloutException e) {
      error = e;
    }
    Long durationMs = System.currentTimeMillis() - startedAt;
    totalCalloutMs += durationMs;

    onCalloutComplete(httpRequest, httpResponse, error, durationMs);
    if (error != null) {
      throw error;
    }
    return httpResponse;
  }

  protected virtual HttpRequest buildHttpRequest(IntegrationRequest request) {
    HttpRequest httpRequest = new HttpRequest();
    httpRequest.setMethod(request.method);
    httpRequest.setEndpoint(buildEndpoint(request));

    Map<String, String> headers = new Map<String, String>(
      getDefaultHeaders() ?? new Map<String, String>()
    );
    headers.putAll(request.headers);
    for (String name : headers.keySet()) {
      httpRequest.setHeader(name, headers.get(name));
    }
    if (request.body != null) {
      httpRequest.setBody(request.body);
    }
    return httpRequest;
  }

  protected virtual String buildEndpoint(IntegrationRequest request) {
    String endpoint = getBaseEndpoint().removeEnd('/');
    if (String.isNotBlank(request.path)) {
      endpoint += '/' + request.path.removeStart('/');
    }

    List<String> params = new List<String>();
    for (String name : request.queryParams.keySet()) {
      params.add(
        EncodingUtil.urlEncode(name, 'UTF-8') +
          '=' +
          EncodingUtil.urlEncode(request.queryParams.get(name) ?? '', 'UTF-8')
      );
    }
    if (!params.isEmpty()) {
      endpoint += (endpoint.contains('?') ? '&' : '?') + String.join(params, '&');
    }
    return endpoint;
  }

  private AccessToken getAccessToken() {
    AccessToken token = getCachedAccessToken();
    if (token == null || token.isExpired()) {
      token = requestAccessToken();
      if (token != null) {
        if (String.isBlank(token.value)) {
          throw new AuthenticationException(
            getIntegrationName() + ' received an empty access token'
          );
        }
        cacheAccessToken(token);
      }
    }
    return token;
  }

  private RateLimitException blockForRateLimit(HttpResponse httpResponse) {
    String retryAfter = httpResponse.getHeader('Retry-After')?.trim();
    Integer retryAfterSeconds = String.isNotBlank(retryAfter) &&
      retryAfter.isNumeric()
      ? Integer.valueOf(retryAfter)
      : getDefaultRetryAfterSeconds();
    rateLimitedUntil.put(
      getIntegrationName(),
      Datetime.now().addSeconds(retryAfterSeconds)
    );
    return newRateLimitException(retryAfterSeconds);
  }

  private RateLimitException newRateLimitException(Integer retryAfterSeconds) {
    RateLimitException e = new RateLimitException(
      getIntegrationName() +
        ' is rate limited; retry after ' +
        retryAfterSeconds +
        ' second(s)'
    );
    e.retryAfterSeconds = retryAfterSeconds;
    return e;
  }

  // ---------------------------------------------------------------------------
  // Types
  // ---------------------------------------------------------------------------

  private class NativeHttpClient implements IntegrationHttpClient {
    public HttpResponse send(HttpRequest request) {
      return new Http().send(request);
    }
  }

  public class IntegrationRequest {
    public String method { get; private set; }
    public String path { get; private set; }
    public Map<String, String> headers { get; private set; }
    public Map<String, String> queryParams { get; private set; }
    public String body { get; private set; }
    public Integer timeoutMs { get; private set; }
    private Boolean retryable;

    /**
     * @param method HTTP method, e.g. 'GET'.
     * @param path   Path appended to the integration's base endpoint, e.g. '/v1/accounts'.
     */
    public IntegrationRequest(String method, String path) {
      if (String.isBlank(method)) {
        throw new IntegrationException('HTTP method is required');
      }
      this.method = method.trim().toUpperCase();
      this.path = path;
      this.headers = new Map<String, String>();
      this.queryParams = new Map<String, String>();
    }

    public IntegrationRequest setHeader(String name, String value) {
      headers.put(name, value);
      return this;
    }

    public IntegrationRequest setQueryParam(String name, String value) {
      queryParams.put(name, value);
      return this;
    }

    public IntegrationRequest setBody(String body) {
      this.body = body;
      return this;
    }

    /** Serializes the payload to JSON, omitting null fields. */
    public IntegrationRequest setJsonBody(Object payload) {
      this.body = JSON.serialize(payload, true);
      return this;
    }

    /** Validates the DTO and uses its JSON as the body. */
    public IntegrationRequest setBody(IntegrationDto payload) {
      this.body = payload.serialize();
      return this;
    }

    /** Overrides the integration's per-attempt timeout for this request. */
    public IntegrationRequest setTimeout(Integer timeoutMs) {
      this.timeoutMs = timeoutMs;
      return this;
    }

    /**
     * Overrides whether transient failures are retried. By default only idempotent methods
     * are; enable it for e.g. a POST protected by an idempotency key.
     */
    public IntegrationRequest setRetryable(Boolean retryable) {
      this.retryable = retryable;
      return this;
    }

    public Boolean isRetryable() {
      return retryable ?? IDEMPOTENT_METHODS.contains(method);
    }
  }

  public class IntegrationResponse {
    public Integer statusCode { get; private set; }
    public String status { get; private set; }
    public String body { get; private set; }
    /** Total callout attempts, including retries and the token-refresh retry. */
    public Integer attempts { get; private set; }
    public Long durationMs { get; private set; }
    public HttpResponse httpResponse { get; private set; }
    private Boolean transientFailure;

    public IntegrationResponse(
      HttpResponse httpResponse,
      Integer attempts,
      Long durationMs
    ) {
      this(httpResponse, attempts, durationMs, false);
    }

    /**
     * @param transientFailure True when the status is one the integration retries, so the
     *        request may succeed if repeated later.
     */
    public IntegrationResponse(
      HttpResponse httpResponse,
      Integer attempts,
      Long durationMs,
      Boolean transientFailure
    ) {
      this.httpResponse = httpResponse;
      this.statusCode = httpResponse.getStatusCode();
      this.status = httpResponse.getStatus();
      this.body = httpResponse.getBody();
      this.attempts = attempts;
      this.durationMs = durationMs;
      this.transientFailure = transientFailure == true;
    }

    public Boolean isSuccess() {
      return statusCode >= 200 && statusCode < 300;
    }

    /**
     * True when the request is retryable and the status is one of the integration's retryable
     * codes (e.g. 503) that persisted through the in-transaction retries.
     */
    public Boolean isTransientFailure() {
      return transientFailure;
    }

    /**
     * Throws TransientResponseException for a transient failure so AsyncCalloutExecutor
     * retries the work later with backoff; returns this response otherwise, e.g.
     * handler.execute(request).throwIfTransientFailure().
     */
    public IntegrationResponse throwIfTransientFailure() {
      if (transientFailure) {
        TransientResponseException e = new TransientResponseException(
          'Transient failure: HTTP ' + statusCode + ' ' + (status ?? '')
        );
        e.statusCode = statusCode;
        throw e;
      }
      return this;
    }

    public String getHeader(String name) {
      return httpResponse.getHeader(name);
    }

    public Object deserialize(Type apexType) {
      return JSON.deserialize(body, apexType);
    }

    /** Parses and validates the body as a DTO, e.g. (OrderDto) response.readBody(OrderDto.class). */
    public IntegrationDto readBody(Type dtoType) {
      return IntegrationDto.deserialize(body, dtoType);
    }

    /** Parses and validates a JSON array body, e.g. (List<OrderDto>) response.readBodyList(OrderDto.class). */
    public List<IntegrationDto> readBodyList(Type dtoType) {
      return IntegrationDto.deserializeList(body, dtoType);
    }
  }

  public class AccessToken {
    public String value { get; private set; }
    public String tokenType { get; private set; }
    public Datetime expiresAt { get; private set; }

    /**
     * @param tokenType        Authorization scheme; defaults to 'Bearer'.
     * @param expiresInSeconds Lifetime reported by the provider, or null if it never expires.
     */
    public AccessToken(String value, String tokenType, Integer expiresInSeconds) {
      this.value = value;
      this.tokenType = String.isBlank(tokenType) ? 'Bearer' : tokenType;
      this.expiresAt = expiresInSeconds == null
        ? null
        : Datetime.now().addSeconds(expiresInSeconds);
    }

    /** True when the token expires within the safety buffer. */
    public Boolean isExpired() {
      return expiresAt != null &&
        Datetime.now().addSeconds(TOKEN_EXPIRY_BUFFER_SECONDS) >= expiresAt;
    }
  }

  public virtual class IntegrationException extends Exception {
  }

  public class AuthenticationException extends IntegrationException {
  }

  public class CalloutLimitException extends IntegrationException {
  }

  public class RateLimitException extends IntegrationException {
    public Integer retryAfterSeconds { get; set; }
  }

  /** A retryable HTTP status that persisted through all in-transaction retries. */
  public class TransientResponseException extends IntegrationException {
    public Integer statusCode { get; set; }
  }
}

@IsTest
private class BaseIntegrationHandlerTest {
  private static final String BASE_ENDPOINT = 'callout:Test_API';

  // Statics are reset for every test method, so each test gets a fresh mock.
  private static fflib_ApexMocks mocks = new fflib_ApexMocks();
  private static IntegrationHttpClient client = (IntegrationHttpClient) mocks.mock(
    IntegrationHttpClient.class
  );

  @IsTest
  static void executeBuildsRequestAndReturnsResponse() {
    mocks.startStubbing();
    mocks.when(client.send(anyRequest()))
      .thenReturn(TestDataFactory.httpResponse(200, '{"id":"42"}'));
    mocks.stopStubbing();

    BaseIntegrationHandler.IntegrationResponse result = new TestHandler(client)
      .execute(
        new BaseIntegrationHandler.IntegrationRequest('get', '/accounts/')
          .setQueryParam('name', 'Acme & Co')
          .setHeader('X-Trace', 'abc')
      );

    Assert.isTrue(result.isSuccess());
    Assert.areEqual(200, result.statusCode);
    Assert.areEqual('{"id":"42"}', result.body);
    Assert.areEqual(1, result.attempts);

    HttpRequest sent = sentRequests(1)[0];
    Assert.areEqual('GET', sent.getMethod());
    Assert.areEqual(
      BASE_ENDPOINT + '/accounts/?name=Acme+%26+Co',
      sent.getEndpoint()
    );
    Assert.areEqual('abc', sent.getHeader('X-Trace'));
    Assert.areEqual('application/json', sent.getHeader('Accept'));
    Assert.isNull(sent.getHeader('Authorization'));
  }

  @IsTest
  static void setJsonBodySerializesPayload() {
    mocks.startStubbing();
    mocks.when(client.send(anyRequest()))
      .thenReturn(TestDataFactory.httpResponse(201, ''));
    mocks.stopStubbing();

    new TestHandler(client)
      .execute(
        new BaseIntegrationHandler.IntegrationRequest('POST', 'accounts')
          .setJsonBody(new Map<String, Object>{ 'name' => 'Acme' })
      );

    HttpRequest sent = sentRequests(1)[0];
    Assert.areEqual('{"name":"Acme"}', sent.getBody());
    Assert.areEqual(BASE_ENDPOINT + '/accounts', sent.getEndpoint());
  }

  @IsTest
  static void retriesTransientFailuresForIdempotentRequests() {
    mocks.startStubbing();
    mocks.when(client.send(anyRequest()))
      .thenReturn(TestDataFactory.httpResponse(503, ''))
      .thenThrow(new CalloutException('Read timed out'))
      .thenReturn(TestDataFactory.httpResponse(200, 'ok'));
    mocks.stopStubbing();
    TestHandler handler = new TestHandler(client);

    BaseIntegrationHandler.IntegrationResponse result = handler.execute(
      new BaseIntegrationHandler.IntegrationRequest('GET', 'accounts')
    );

    Assert.isTrue(result.isSuccess());
    Assert.areEqual(3, result.attempts);
    Assert.areEqual(3, handler.calloutsObserved);
    sentRequests(3);
  }

  @IsTest
  static void returnsLastResponseWhenRetriesAreExhausted() {
    mocks.startStubbing();
    mocks.when(client.send(anyRequest()))
      .thenReturn(TestDataFactory.httpResponse(500, ''))
      .thenReturn(TestDataFactory.httpResponse(500, ''))
      .thenReturn(TestDataFactory.httpResponse(500, 'still down'));
    mocks.stopStubbing();

    BaseIntegrationHandler.IntegrationResponse result = new TestHandler(client)
      .execute(
        new BaseIntegrationHandler.IntegrationRequest('GET', 'accounts')
      );

    Assert.isFalse(result.isSuccess());
    Assert.areEqual(500, result.statusCode);
    Assert.areEqual('still down', result.body);
    Assert.areEqual(3, result.attempts);
    Assert.isTrue(result.isTransientFailure());
    try {
      result.throwIfTransientFailure();
      Assert.fail('Expected TransientResponseException');
    } catch (BaseIntegrationHandler.TransientResponseException e) {
      Assert.areEqual(500, e.statusCode);
    }
  }

  @IsTest
  static void nonRetryableStatusIsNotTransient() {
    mocks.startStubbing();
    mocks.when(client.send(anyRequest()))
      .thenReturn(TestDataFactory.httpResponse(404, ''))
      .thenReturn(TestDataFactory.httpResponse(200, ''));
    mocks.stopStubbing();
    TestHandler handler = new TestHandler(client);

    for (Integer statusCode : new List<Integer>{ 404, 200 }) {
      BaseIntegrationHandler.IntegrationResponse result = handler.execute(
        new BaseIntegrationHandler.IntegrationRequest('GET', 'accounts')
      );

      Assert.areEqual(statusCode, result.statusCode);
      Assert.isFalse(result.isTransientFailure());
      Assert.areEqual(result, result.throwIfTransientFailure());
    }
  }

  @IsTest
  static void throwsWhenNoResponseAfterRetries() {
    mocks.startStubbing();
    mocks.when(client.send(anyRequest()))
      .thenThrow(new CalloutException('Read timed out'));
    mocks.stopStubbing();

    try {
      new TestHandler(client)
        .execute(
          new BaseIntegrationHandler.IntegrationRequest('GET', 'accounts')
        );
      Assert.fail('Expected IntegrationException');
    } catch (BaseIntegrationHandler.IntegrationException e) {
      Assert.isInstanceOfType(e.getCause(), CalloutException.class);
    }
    sentRequests(3);
  }

  @IsTest
  static void doesNotRetryNonIdempotentRequestsByDefault() {
    mocks.startStubbing();
    mocks.when(client.send(anyRequest()))
      .thenReturn(TestDataFactory.httpResponse(503, ''))
      .thenReturn(TestDataFactory.httpResponse(200, ''));
    mocks.stopStubbing();

    BaseIntegrationHandler.IntegrationResponse result = new TestHandler(client)
      .execute(
        new BaseIntegrationHandler.IntegrationRequest('POST', 'accounts')
      );

    Assert.areEqual(503, result.statusCode);
    // Not repeated now, so not repeated later either.
    Assert.isFalse(result.isTransientFailure());
    sentRequests(1);
  }

  @IsTest
  static void retriesNonIdempotentRequestsMarkedRetryable() {
    mocks.startStubbing();
    mocks.when(client.send(anyRequest()))
      .thenReturn(TestDataFactory.httpResponse(503, ''))
      .thenReturn(TestDataFactory.httpResponse(200, ''));
    mocks.stopStubbing();

    BaseIntegrationHandler.IntegrationResponse result = new TestHandler(client)
      .execute(
        new BaseIntegrationHandler.IntegrationRequest('POST', 'accounts')
          .setRetryable(true)
      );

    Assert.areEqual(200, result.statusCode);
    Assert.areEqual(2, result.attempts);
  }

  @IsTest
  static void doesNotRetryWhenMaxRetriesIsZero() {
    mocks.startStubbing();
    mocks.when(client.send(anyRequest()))
      .thenReturn(TestDataFactory.httpResponse(503, ''))
      .thenReturn(TestDataFactory.httpResponse(200, ''));
    mocks.stopStubbing();
    TestHandler handler = new TestHandler(client);
    handler.maxRetries = 0;

    BaseIntegrationHandler.IntegrationResponse result = handler.execute(
      new BaseIntegrationHandler.IntegrationRequest('GET', 'accounts')
    );

    Assert.areEqual(503, result.statusCode);
    sentRequests(1);
  }

  @IsTest
  static void appliesAndCachesAccessToken() {
    mocks.startStubbing();
    mocks.when(client.send(anyRequest()))
      .thenReturn(TestDataFactory.httpResponse(200, ''));
    mocks.stopStubbing();
    TestHandler handler = new TestHandler(client);
    handler.useToken = true;

    handler.execute(new BaseIntegrationHandler.IntegrationRequest('GET', 'a'));
    // The token is cached per integration name, so a second instance reuses it.
    new TestHandler(client)
      .execute(new BaseIntegrationHandler.IntegrationRequest('GET', 'b'));

    Assert.areEqual(1, handler.tokenRequests);
    List<HttpRequest> sent = sentRequests(2);
    Assert.areEqual('Bearer token-1', sent[0].getHeader('Authorization'));
    Assert.areEqual('Bearer token-1', sent[1].getHeader('Authorization'));
  }

  @IsTest
  static void refreshesExpiredAccessToken() {
    mocks.startStubbing();
    mocks.when(client.send(anyRequest()))
      .thenReturn(TestDataFactory.httpResponse(200, ''));
    mocks.stopStubbing();
    TestHandler handler = new TestHandler(client);
    handler.useToken = true;
    handler.tokenLifetimeSeconds = 30; // inside the expiry buffer

    handler.execute(new BaseIntegrationHandler.IntegrationRequest('GET', 'a'));
    handler.execute(new BaseIntegrationHandler.IntegrationRequest('GET', 'b'));

    Assert.areEqual(2, handler.tokenRequests);
    Assert.areEqual(
      'Bearer token-2',
      sentRequests(2)[1].getHeader('Authorization')
    );
  }

  @IsTest
  static void refreshesTokenOnceOnUnauthorized() {
    mocks.startStubbing();
    mocks.when(client.send(anyRequest()))
      .thenReturn(TestDataFactory.httpResponse(401, ''))
      .thenReturn(TestDataFactory.httpResponse(200, 'ok'));
    mocks.stopStubbing();
    TestHandler handler = new TestHandler(client);
    handler.useToken = true;

    BaseIntegrationHandler.IntegrationResponse result = handler.execute(
      new BaseIntegrationHandler.IntegrationRequest('POST', 'accounts')
    );

    Assert.areEqual(200, result.statusCode);
    Assert.areEqual(2, result.attempts);
    Assert.areEqual(2, handler.tokenRequests);
    List<HttpRequest> sent = sentRequests(2);
    Assert.areEqual('Bearer token-1', sent[0].getHeader('Authorization'));
    Assert.areEqual('Bearer token-2', sent[1].getHeader('Authorization'));
  }

  @IsTest
  static void returnsUnauthorizedWhenRefreshDoesNotHelp() {
    mocks.startStubbing();
    mocks.when(client.send(anyRequest()))
      .thenReturn(TestDataFactory.httpResponse(401, 'denied'));
    mocks.stopStubbing();
    TestHandler handler = new TestHandler(client);
    handler.useToken = true;

    BaseIntegrationHandler.IntegrationResponse result = handler.execute(
      new BaseIntegrationHandler.IntegrationRequest('GET', 'accounts')
    );

    Assert.areEqual(401, result.statusCode);
    sentRequests(2);
  }

  @IsTest
  static void doesNotRetryUnauthorizedWithoutToken() {
    mocks.startStubbing();
    mocks.when(client.send(anyRequest()))
      .thenReturn(TestDataFactory.httpResponse(401, ''));
    mocks.stopStubbing();

    BaseIntegrationHandler.IntegrationResponse result = new TestHandler(client)
      .execute(
        new BaseIntegrationHandler.IntegrationRequest('GET', 'accounts')
      );

    Assert.areEqual(401, result.statusCode);
    sentRequests(1);
  }

  @IsTest
  static void throwsWhenAccessTokenIsEmpty() {
    TestHandler handler = new TestHandler(client);
    handler.useToken = true;
    handler.tokenValue = '';

    try {
      handler.execute(
        new BaseIntegrationHandler.IntegrationRequest('GET', 'accounts')
      );
      Assert.fail('Expected AuthenticationException');
    } catch (BaseIntegrationHandler.AuthenticationException e) {
      ((IntegrationHttpClient) mocks.verify(client, mocks.never()))
        .send(anyRequest());
    }
  }

  @IsTest
  static void rateLimitedResponseThrowsAndBlocksFurtherCallouts() {
    HttpResponse tooManyRequests = TestDataFactory.httpResponse(429, '');
    tooManyRequests.setHeader('Retry-After', '120');
    mocks.startStubbing();
    mocks.when(client.send(anyRequest()))
      .thenReturn(tooManyRequests)
      .thenReturn(TestDataFactory.httpResponse(200, ''));
    mocks.stopStubbing();
    TestHandler handler = new TestHandler(client);

    try {
      handler.execute(
        new BaseIntegrationHandler.IntegrationRequest('GET', 'accounts')
      );
      Assert.fail('Expected RateLimitException');
    } catch (BaseIntegrationHandler.RateLimitException e) {
      Assert.areEqual(120, e.retryAfterSeconds);
    }

    try {
      handler.execute(
        new BaseIntegrationHandler.IntegrationRequest('GET', 'accounts')
      );
      Assert.fail('Expected RateLimitException');
    } catch (BaseIntegrationHandler.RateLimitException e) {
      Assert.isTrue(e.retryAfterSeconds > 0 && e.retryAfterSeconds <= 121);
    }
    sentRequests(1);
  }

  @IsTest
  static void rateLimitWithoutRetryAfterUsesDefault() {
    mocks.startStubbing();
    mocks.when(client.send(anyRequest()))
      .thenReturn(TestDataFactory.httpResponse(429, ''));
    mocks.stopStubbing();

    try {
      new TestHandler(client)
        .execute(
          new BaseIntegrationHandler.IntegrationRequest('GET', 'accounts')
        );
      Assert.fail('Expected RateLimitException');
    } catch (BaseIntegrationHandler.RateLimitException e) {
      Assert.areEqual(60, e.retryAfterSeconds);
    }
  }

  @IsTest
  static void enforcesCalloutsPerTransactionCap() {
    mocks.startStubbing();
    mocks.when(client.send(anyRequest()))
      .thenReturn(TestDataFactory.httpResponse(200, ''));
    mocks.stopStubbing();
    TestHandler handler = new TestHandler(client);
    handler.maxCalloutsPerTransaction = 1;

    handler.execute(new BaseIntegrationHandler.IntegrationRequest('GET', 'a'));
    try {
      handler.execute(
        new BaseIntegrationHandler.IntegrationRequest('GET', 'b')
      );
      Assert.fail('Expected CalloutLimitException');
    } catch (BaseIntegrationHandler.CalloutLimitException e) {
      sentRequests(1);
    }
  }

  @IsTest
  static void requestRequiresMethod() {
    try {
      new BaseIntegrationHandler.IntegrationRequest(' ', 'accounts');
      Assert.fail('Expected IntegrationException');
    } catch (BaseIntegrationHandler.IntegrationException e) {
      Assert.isNotNull(e.getMessage());
    }
  }

  /**
   * Covers the default transport. The real Http class cannot be stubbed with the
   * Stub API, so this one test uses the platform's HttpCalloutMock.
   */
  @IsTest
  static void sendsThroughHttpByDefault() {
    Test.setMock(
      HttpCalloutMock.class,
      new FixedCalloutMock(TestDataFactory.httpResponse(200, 'ok'))
    );

    BaseIntegrationHandler.IntegrationResponse result = new TestHandler()
      .execute(
        new BaseIntegrationHandler.IntegrationRequest('GET', 'accounts')
      );

    Assert.areEqual('ok', result.body);
  }

  private static HttpRequest anyRequest() {
    return (HttpRequest) fflib_Match.anyObject();
  }

  /** Verifies the client was called exactly the given number of times and returns the requests. */
  private static List<HttpRequest> sentRequests(Integer times) {
    fflib_ArgumentCaptor captor = fflib_ArgumentCaptor.forClass(
      HttpRequest.class
    );
    ((IntegrationHttpClient) mocks.verify(client, times))
      .send((HttpRequest) captor.capture());

    List<HttpRequest> requests = new List<HttpRequest>();
    for (Object request : captor.getAllValues()) {
      requests.add((HttpRequest) request);
    }
    return requests;
  }

  private class TestHandler extends BaseIntegrationHandler {
    public Integer maxRetries = 2;
    public Integer maxCalloutsPerTransaction;
    public Boolean useToken = false;
    public String tokenValue;
    public Integer tokenLifetimeSeconds = 3600;
    public Integer tokenRequests = 0;
    public Integer calloutsObserved = 0;

    public TestHandler() {
    }

    public TestHandler(IntegrationHttpClient httpClient) {
      setHttpClient(httpClient);
    }

    protected override String getIntegrationName() {
      return 'TestIntegration';
    }

    protected override String getBaseEndpoint() {
      return BASE_ENDPOINT;
    }

    protected override Integer getMaxRetries() {
      return maxRetries;
    }

    protected override Integer getMaxCalloutsPerTransaction() {
      return maxCalloutsPerTransaction;
    }

    protected override BaseIntegrationHandler.AccessToken requestAccessToken() {
      if (!useToken) {
        return null;
      }
      tokenRequests++;
      return new BaseIntegrationHandler.AccessToken(
        tokenValue ?? 'token-' + tokenRequests,
        null,
        tokenLifetimeSeconds
      );
    }

    protected override void onCalloutComplete(
      HttpRequest httpRequest,
      HttpResponse httpResponse,
      Exception error,
      Long durationMs
    ) {
      calloutsObserved++;
    }
  }

  private class FixedCalloutMock implements HttpCalloutMock {
    private HttpResponse httpResponse;

    public FixedCalloutMock(HttpResponse httpResponse) {
      this.httpResponse = httpResponse;
    }

    public HttpResponse respond(HttpRequest request) {
      return httpResponse;
    }
  }
}

/**
 * Exponential backoff policy for asynchronous retries.
 *
 * The delay before retry n (1-based) is initialDelayMs * multiplier^(n - 1), capped at
 * maxDelayMs; e.g. 60000 ms with multiplier 2 waits 1, 2, 4, 8 minutes. Apex cannot sleep, so
 * the delay is applied by re-enqueueing the work (see AsyncCalloutExecutor), which rounds up to
 * whole minutes and allows at most 10.
 *
 * isRetryable() decides which failures are worth retrying; override it for custom rules.
 * Instances travel inside Queueables, so subclasses must stay serializable.
 */
public virtual inherited sharing class ExponentialBackoffRetry {
  /** Longest delay a Queueable can be enqueued with. */
  public static final Integer MAX_QUEUEABLE_DELAY_MS = 600000;
  @TestVisible
  private static final Integer DEFAULT_INITIAL_DELAY_MS = 60000;
  @TestVisible
  private static final Decimal DEFAULT_MULTIPLIER = 2;
  @TestVisible
  private static final Integer DEFAULT_MAX_RETRIES = 3;

  /** Up to 3 retries after 1, 2 and 4 minutes. */
  public static ExponentialBackoffRetry withDefaults() {
    return new ExponentialBackoffRetry(
      DEFAULT_INITIAL_DELAY_MS,
      DEFAULT_MULTIPLIER,
      DEFAULT_MAX_RETRIES
    );
  }

  /**
   * Policy for a configured integration: Retry_Delay_Ms__c is the initial delay (1 minute when
   * blank), with the default multiplier and retry count. Max_Retries__c is not used here; it
   * limits the immediate in-transaction retries.
   *
   * @throws IntegrationConfigLoader.ConfigurationException when the integration has no active,
   *         valid configuration.
   */
  public static ExponentialBackoffRetry forIntegration(String integrationName) {
    IntegrationConfigLoader.IntegrationConfig config = IntegrationConfigLoader.load(
      integrationName
    );
    return new ExponentialBackoffRetry(
      config.retryDelayMs ?? DEFAULT_INITIAL_DELAY_MS,
      DEFAULT_MULTIPLIER,
      DEFAULT_MAX_RETRIES
    );
  }

  public Integer initialDelayMs { get; private set; }
  public Decimal multiplier { get; private set; }
  public Integer maxRetries { get; private set; }
  public Integer maxDelayMs { get; private set; }

  public ExponentialBackoffRetry(
    Integer initialDelayMs,
    Decimal multiplier,
    Integer maxRetries
  ) {
    this(initialDelayMs, multiplier, maxRetries, MAX_QUEUEABLE_DELAY_MS);
  }

  /**
   * @param initialDelayMs Delay before the first retry; 0 or more.
   * @param multiplier     Factor applied to the delay after each retry; 1 or more.
   * @param maxRetries     Retries allowed after the first attempt; 0 disables retries.
   * @param maxDelayMs     Upper bound for any single delay; 0 or more.
   */
  public ExponentialBackoffRetry(
    Integer initialDelayMs,
    Decimal multiplier,
    Integer maxRetries,
    Integer maxDelayMs
  ) {
    if (initialDelayMs == null || initialDelayMs < 0) {
      throw new BaseIntegrationHandler.IntegrationException(
        'Initial delay must be 0 or more milliseconds'
      );
    }
    if (multiplier == null || multiplier < 1) {
      throw new BaseIntegrationHandler.IntegrationException(
        'Backoff multiplier must be at least 1'
      );
    }
    if (maxRetries == null || maxRetries < 0) {
      throw new BaseIntegrationHandler.IntegrationException(
        'Max retries must be 0 or more'
      );
    }
    if (maxDelayMs == null || maxDelayMs < 0) {
      throw new BaseIntegrationHandler.IntegrationException(
        'Max delay must be 0 or more milliseconds'
      );
    }
    this.initialDelayMs = initialDelayMs;
    this.multiplier = multiplier;
    this.maxRetries = maxRetries;
    this.maxDelayMs = maxDelayMs;
  }

  /** True while fewer than maxRetries retries have been made. */
  public Boolean canRetry(Integer retriesSoFar) {
    return (retriesSoFar ?? 0) < maxRetries;
  }

  /** Delay before the given retry, where 1 is the first retry. */
  public Integer getDelayMs(Integer retryNumber) {
    if (retryNumber == null || retryNumber < 1) {
      throw new BaseIntegrationHandler.IntegrationException(
        'Retry number must be at least 1'
      );
    }
    // Multiplied step by step so a large retry number cannot overflow before the cap applies.
    Decimal delayMs = initialDelayMs;
    for (Integer i = 1; i < retryNumber && delayMs < maxDelayMs; i++) {
      delayMs *= multiplier;
    }
    return Math.min(delayMs, maxDelayMs)
      .round(System.RoundingMode.CEILING)
      .intValue();
  }

  /**
   * Transient failures are retried: rate limits, spent callout budgets, retryable HTTP statuses
   * (see IntegrationResponse.throwIfTransientFailure()) and connection errors, including an
   * IntegrationException caused by one. Everything else (configuration, authentication, DTO
   * validation, bugs) would fail the same way again.
   */
  public virtual Boolean isRetryable(Exception error) {
    return error instanceof BaseIntegrationHandler.RateLimitException ||
      error instanceof BaseIntegrationHandler.CalloutLimitException ||
      error instanceof BaseIntegrationHandler.TransientResponseException ||
      error instanceof CalloutException ||
      error?.getCause() instanceof CalloutException;
  }
}

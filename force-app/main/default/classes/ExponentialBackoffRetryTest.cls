@IsTest
private class ExponentialBackoffRetryTest {
  @IsTest
  static void delaysGrowByMultiplierUpToTheCap() {
    ExponentialBackoffRetry retry = new ExponentialBackoffRetry(
      60000,
      2,
      5
    );

    Assert.areEqual(60000, retry.getDelayMs(1));
    Assert.areEqual(120000, retry.getDelayMs(2));
    Assert.areEqual(240000, retry.getDelayMs(3));
    Assert.areEqual(480000, retry.getDelayMs(4));
    Assert.areEqual(
      ExponentialBackoffRetry.MAX_QUEUEABLE_DELAY_MS,
      retry.getDelayMs(5)
    );
    // A large retry number stops multiplying at the cap instead of overflowing.
    Assert.areEqual(
      ExponentialBackoffRetry.MAX_QUEUEABLE_DELAY_MS,
      retry.getDelayMs(1000)
    );
  }

  @IsTest
  static void supportsFractionalMultiplierAndCustomCap() {
    ExponentialBackoffRetry retry = new ExponentialBackoffRetry(
      1000,
      1.5,
      3,
      3000
    );

    Assert.areEqual(1000, retry.getDelayMs(1));
    Assert.areEqual(1500, retry.getDelayMs(2));
    Assert.areEqual(2250, retry.getDelayMs(3));
    Assert.areEqual(3000, retry.getDelayMs(4));
  }

  @IsTest
  static void multiplierOfOneKeepsDelayConstant() {
    ExponentialBackoffRetry retry = new ExponentialBackoffRetry(500, 1, 3);

    Assert.areEqual(500, retry.getDelayMs(1));
    Assert.areEqual(500, retry.getDelayMs(3));
  }

  @IsTest
  static void canRetryUntilMaxRetries() {
    ExponentialBackoffRetry retry = new ExponentialBackoffRetry(0, 2, 2);

    Assert.isTrue(retry.canRetry(null));
    Assert.isTrue(retry.canRetry(0));
    Assert.isTrue(retry.canRetry(1));
    Assert.isFalse(retry.canRetry(2));
    Assert.isFalse(new ExponentialBackoffRetry(0, 2, 0).canRetry(0));
  }

  @IsTest
  static void retriesOnlyTransientFailures() {
    ExponentialBackoffRetry retry = new ExponentialBackoffRetry(0, 2, 2);

    Assert.isTrue(
      retry.isRetryable(new BaseIntegrationHandler.RateLimitException())
    );
    Assert.isTrue(
      retry.isRetryable(new BaseIntegrationHandler.CalloutLimitException())
    );
    Assert.isTrue(retry.isRetryable(new CalloutException('Read timed out')));
    Assert.isTrue(
      retry.isRetryable(
        new BaseIntegrationHandler.IntegrationException(
          'Callout failed',
          new CalloutException('Read timed out')
        )
      )
    );
    Assert.isFalse(
      retry.isRetryable(
        new BaseIntegrationHandler.IntegrationException('Request is required')
      )
    );
    Assert.isFalse(
      retry.isRetryable(new BaseIntegrationHandler.AuthenticationException())
    );
    Assert.isFalse(
      retry.isRetryable(new IntegrationConfigLoader.ConfigurationException())
    );
    Assert.isFalse(retry.isRetryable(new NullPointerException()));
    Assert.isFalse(retry.isRetryable(null));
  }

  @IsTest
  static void rejectsInvalidSettings() {
    assertInvalid(
      null,
      2,
      1,
      0,
      'Initial delay must be 0 or more milliseconds'
    );
    assertInvalid(
      -1,
      2,
      1,
      0,
      'Initial delay must be 0 or more milliseconds'
    );
    assertInvalid(0, 0.5, 1, 0, 'Backoff multiplier must be at least 1');
    assertInvalid(0, null, 1, 0, 'Backoff multiplier must be at least 1');
    assertInvalid(0, 2, -1, 0, 'Max retries must be 0 or more');
    assertInvalid(0, 2, 1, -1, 'Max delay must be 0 or more milliseconds');
    try {
      new ExponentialBackoffRetry(0, 2, 1).getDelayMs(0);
      Assert.fail('Expected an IntegrationException');
    } catch (BaseIntegrationHandler.IntegrationException e) {
      Assert.areEqual('Retry number must be at least 1', e.getMessage());
    }
  }

  private static void assertInvalid(
    Integer initialDelayMs,
    Decimal multiplier,
    Integer maxRetries,
    Integer maxDelayMs,
    String expectedMessage
  ) {
    try {
      new ExponentialBackoffRetry(
        initialDelayMs,
        multiplier,
        maxRetries,
        maxDelayMs
      );
      Assert.fail('Expected an IntegrationException');
    } catch (BaseIntegrationHandler.IntegrationException e) {
      Assert.areEqual(expectedMessage, e.getMessage());
    }
  }
}

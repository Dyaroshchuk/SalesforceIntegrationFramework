@IsTest
private class AsyncCalloutExecutorTest {
  // Stub API mocks cannot be serialized into a Queueable, so a hand-written fake records calls.
  private static Integer executions = 0;
  private static List<Exception> failures = new List<Exception>();

  static {
    AsyncCalloutExecutor.retryDelaysMinutes = new List<Integer>();
  }

  @IsTest
  static void enqueueRunsCalloutAsynchronously() {
    Test.startTest();
    Id jobId = AsyncCalloutExecutor.enqueue(new FakeCallout(null));
    Assert.areEqual(0, executions);
    Test.stopTest();

    Assert.isNotNull(jobId);
    Assert.areEqual(1, executions);
    Assert.isTrue(failures.isEmpty());
  }

  @IsTest
  static void retriesTransientFailuresWithBackoffThenReportsFailure() {
    CalloutException error = new CalloutException('Read timed out');
    AsyncCalloutExecutor executor = new AsyncCalloutExecutor(
      new FakeCallout(error)
    );

    // In production each retry is a new Queueable run; here the runs are made directly.
    for (Integer i = 0; i < 4; i++) {
      executor.execute(null);
    }

    Assert.areEqual(4, executions);
    Assert.areEqual(4, executor.getAttempts());
    // Default policy: 3 retries after 1, 2 and 4 minutes, then the failure is reported.
    Assert.areEqual(
      new List<Integer>{ 1, 2, 4 },
      AsyncCalloutExecutor.retryDelaysMinutes
    );
    Assert.areEqual(1, failures.size());
    Assert.areEqual(error, failures[0]);

    Test.getEventBus().deliver();
    List<Log__c> logs = [
      SELECT Category__c, Level__c, Message__c
      FROM Log__c
      WITH SYSTEM_MODE
      ORDER BY Name
    ];
    Assert.areEqual(4, logs.size());
    for (Integer i = 0; i < 3; i++) {
      Assert.areEqual('WARN', logs[i].Level__c);
      Assert.isTrue(
        logs[i].Message__c.contains('retrying in'),
        logs[i].Message__c
      );
    }
    Assert.areEqual('ERROR', logs[3].Level__c);
    Assert.areEqual(
      'Async callout failed after 4 attempt(s): Read timed out',
      logs[3].Message__c
    );
    Assert.areEqual('Integration', logs[3].Category__c);
  }

  @IsTest
  static void forIntegrationUsesConfiguredPolicyAndNamesLogs() {
    Integration_Configuration__mdt record = TestDataFactory.integrationConfig(
      'Billing',
      'Billing_API'
    );
    record.Retry_Delay_Ms__c = 120000;
    TestDataFactory.useIntegrationConfig(record);
    AsyncCalloutExecutor executor = AsyncCalloutExecutor.forIntegration(
      'Billing',
      new FakeCallout(new CalloutException('Read timed out'))
    );

    executor.execute(null);
    Test.getEventBus().deliver();

    // Retry_Delay_Ms__c of 2 minutes is the first backoff delay.
    Assert.areEqual(
      new List<Integer>{ 2 },
      AsyncCalloutExecutor.retryDelaysMinutes
    );
    Log__c log = [
      SELECT Integration_Name__c, Level__c
      FROM Log__c
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    Assert.areEqual('Billing', log.Integration_Name__c);
    Assert.areEqual('WARN', log.Level__c);
  }

  @IsTest
  static void rateLimitWaitsForLongerOfRetryAfterAndBackoff() {
    new AsyncCalloutExecutor(new FakeCallout(rateLimit(150))).execute(null);
    new AsyncCalloutExecutor(new FakeCallout(rateLimit(30))).execute(null);
    new AsyncCalloutExecutor(new FakeCallout(rateLimit(null))).execute(null);

    // 150 s beats the 1 minute backoff (rounded up to 3 minutes); 30 s and none do not.
    Assert.areEqual(
      new List<Integer>{ 3, 1, 1 },
      AsyncCalloutExecutor.retryDelaysMinutes
    );
    Assert.isTrue(failures.isEmpty());
  }

  @IsTest
  static void usesCustomRetryPolicy() {
    AsyncCalloutExecutor executor = new AsyncCalloutExecutor(
      new FakeCallout(rateLimit(0)),
      new ExponentialBackoffRetry(120000, 3, 1)
    );

    executor.execute(null);
    executor.execute(null);

    Assert.areEqual(
      new List<Integer>{ 2 },
      AsyncCalloutExecutor.retryDelaysMinutes
    );
    Assert.areEqual(1, failures.size());
  }

  @IsTest
  static void reportsNonRetryableFailureWithoutRetrying() {
    BaseIntegrationHandler.IntegrationException error = new BaseIntegrationHandler.IntegrationException(
      'Request is required'
    );

    new AsyncCalloutExecutor(new FakeCallout(error)).execute(null);

    Assert.areEqual(1, executions);
    Assert.isTrue(AsyncCalloutExecutor.retryDelaysMinutes.isEmpty());
    Assert.areEqual(1, failures.size());
    Assert.areEqual(error, failures[0]);
  }

  @IsTest
  static void toDelayMinutesRoundsUpAndCaps() {
    Assert.areEqual(0, AsyncCalloutExecutor.toDelayMinutes(null));
    Assert.areEqual(0, AsyncCalloutExecutor.toDelayMinutes(0));
    Assert.areEqual(1, AsyncCalloutExecutor.toDelayMinutes(1));
    Assert.areEqual(1, AsyncCalloutExecutor.toDelayMinutes(60000));
    Assert.areEqual(2, AsyncCalloutExecutor.toDelayMinutes(60001));
    Assert.areEqual(
      AsyncCalloutExecutor.MAX_DELAY_MINUTES,
      AsyncCalloutExecutor.toDelayMinutes(3600000)
    );
  }

  @IsTest
  static void constructorValidatesArguments() {
    try {
      new AsyncCalloutExecutor(null);
      Assert.fail('Expected an IntegrationException');
    } catch (BaseIntegrationHandler.IntegrationException e) {
      Assert.areEqual('Callout is required', e.getMessage());
    }
    try {
      new AsyncCalloutExecutor(new FakeCallout(null), null);
      Assert.fail('Expected an IntegrationException');
    } catch (BaseIntegrationHandler.IntegrationException e) {
      Assert.areEqual('Retry policy is required', e.getMessage());
    }
  }

  private static BaseIntegrationHandler.RateLimitException rateLimit(
    Integer retryAfterSeconds
  ) {
    BaseIntegrationHandler.RateLimitException e = new BaseIntegrationHandler.RateLimitException(
      'Rate limited'
    );
    e.retryAfterSeconds = retryAfterSeconds;
    return e;
  }

  /** Throws the given exception from every run, or succeeds when it is null. */
  private class FakeCallout implements ICalloutQueueable {
    private final Exception error;

    FakeCallout(Exception error) {
      this.error = error;
    }

    public void execute() {
      executions++;
      if (error != null) {
        throw error;
      }
    }

    public void onFailure(Exception error) {
      failures.add(error);
    }
  }
}

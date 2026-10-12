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
  static void reEnqueuesWithDelayWhenRateLimited() {
    AsyncCalloutExecutor executor = new AsyncCalloutExecutor(
      new FakeCallout(rateLimit(90))
    );

    executor.execute(null);

    Assert.areEqual(1, executions);
    Assert.areEqual(1, executor.getAttempts());
    // Retry-After of 90 seconds rounds up to a 2 minute delay.
    Assert.areEqual(
      new List<Integer>{ 2 },
      AsyncCalloutExecutor.retryDelaysMinutes
    );
    Assert.isTrue(failures.isEmpty());
  }

  @IsTest
  static void reportsRateLimitOnLastAttempt() {
    BaseIntegrationHandler.RateLimitException error = rateLimit(30);
    AsyncCalloutExecutor executor = new AsyncCalloutExecutor(
      new FakeCallout(error),
      2
    );

    executor.execute(null);
    executor.execute(null);

    Assert.areEqual(2, executions);
    // Only the first run re-enqueued; the second reached maxAttempts.
    Assert.areEqual(
      new List<Integer>{ 1 },
      AsyncCalloutExecutor.retryDelaysMinutes
    );
    Assert.areEqual(1, failures.size());
    Assert.areEqual(error, failures[0]);
  }

  @IsTest
  static void reportsOtherExceptionsWithoutRetrying() {
    BaseIntegrationHandler.IntegrationException error = new BaseIntegrationHandler.IntegrationException(
      'Billing callout failed'
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
    Assert.areEqual(1, AsyncCalloutExecutor.toDelayMinutes(60));
    Assert.areEqual(2, AsyncCalloutExecutor.toDelayMinutes(61));
    Assert.areEqual(
      AsyncCalloutExecutor.MAX_DELAY_MINUTES,
      AsyncCalloutExecutor.toDelayMinutes(3600)
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
      new AsyncCalloutExecutor(new FakeCallout(null), 0);
      Assert.fail('Expected an IntegrationException');
    } catch (BaseIntegrationHandler.IntegrationException e) {
      Assert.areEqual('Max attempts must be at least 1', e.getMessage());
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

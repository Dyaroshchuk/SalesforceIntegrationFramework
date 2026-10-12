/**
 * Runs an ICalloutQueueable in its own asynchronous transaction with callouts allowed.
 *
 * When the work throws, the executor asks its ExponentialBackoffRetry policy whether to try
 * again. If so it re-enqueues itself after the backoff delay; for a rate limit, after the
 * Retry-After time if that is longer. Delays are rounded up to whole minutes and capped at the
 * platform maximum of 10. A failure that is not retryable, or that remains after the last retry,
 * is passed to ICalloutQueueable.onFailure().
 *
 * Usage: AsyncCalloutExecutor.enqueue(new SyncInvoiceCallout(invoiceId));
 */
public inherited sharing class AsyncCalloutExecutor implements Queueable, Database.AllowsCallouts {
  @TestVisible
  private static final Integer MAX_DELAY_MINUTES = 10;

  // Test seam: Apex tests cannot reliably chain Queueables, so when set, retries record
  // their delay here instead of being enqueued.
  @TestVisible
  private static List<Integer> retryDelaysMinutes;

  private final ICalloutQueueable callout;
  private final ExponentialBackoffRetry retryPolicy;
  private Integer attempts = 0;

  /** Uses the default policy: up to 3 retries after 1, 2 and 4 minutes. */
  public AsyncCalloutExecutor(ICalloutQueueable callout) {
    this(callout, new ExponentialBackoffRetry(60000, 2, 3));
  }

  public AsyncCalloutExecutor(
    ICalloutQueueable callout,
    ExponentialBackoffRetry retryPolicy
  ) {
    if (callout == null) {
      throw new BaseIntegrationHandler.IntegrationException(
        'Callout is required'
      );
    }
    if (retryPolicy == null) {
      throw new BaseIntegrationHandler.IntegrationException(
        'Retry policy is required'
      );
    }
    this.callout = callout;
    this.retryPolicy = retryPolicy;
  }

  /** Enqueues the callout to run as soon as possible and returns the job Id. */
  public static Id enqueue(ICalloutQueueable callout) {
    return new AsyncCalloutExecutor(callout).enqueue(0);
  }

  /** Enqueues this executor after the given delay (0-10 minutes) and returns the job Id. */
  public Id enqueue(Integer delayMinutes) {
    return System.enqueueJob(this, delayMinutes);
  }

  public void execute(QueueableContext context) {
    attempts++;
    try {
      callout.execute();
    } catch (Exception e) {
      if (!retryLater(e)) {
        callout.onFailure(e);
      }
    }
  }

  @TestVisible
  private Integer getAttempts() {
    return attempts;
  }

  private Boolean retryLater(Exception error) {
    Integer retries = attempts - 1;
    if (
      !retryPolicy.isRetryable(error) ||
      !retryPolicy.canRetry(retries) ||
      Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()
    ) {
      return false;
    }
    Long delayMs = retryPolicy.getDelayMs(retries + 1);
    if (error instanceof BaseIntegrationHandler.RateLimitException) {
      Integer retryAfterSeconds = ((BaseIntegrationHandler.RateLimitException) error)
        .retryAfterSeconds;
      delayMs = Math.max(delayMs, (retryAfterSeconds ?? 0) * 1000L);
    }
    Integer delayMinutes = toDelayMinutes(delayMs);
    if (retryDelaysMinutes != null) {
      retryDelaysMinutes.add(delayMinutes);
    } else {
      enqueue(delayMinutes);
    }
    return true;
  }

  @TestVisible
  private static Integer toDelayMinutes(Long delayMs) {
    if (delayMs == null || delayMs <= 0) {
      return 0;
    }
    Integer minutes = (Integer) Math.ceil(delayMs / 60000.0);
    return Math.min(minutes, MAX_DELAY_MINUTES);
  }
}

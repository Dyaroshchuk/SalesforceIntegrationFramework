/**
 * Runs an ICalloutQueueable in its own asynchronous transaction with callouts allowed.
 *
 * When the work throws BaseIntegrationHandler.RateLimitException the executor re-enqueues
 * itself, delayed by the exception's retryAfterSeconds (rounded up to whole minutes and capped
 * at the platform maximum of 10), until maxAttempts is reached. Any other exception, or a rate
 * limit on the last attempt, is passed to ICalloutQueueable.onFailure().
 *
 * Usage: AsyncCalloutExecutor.enqueue(new SyncInvoiceCallout(invoiceId));
 */
public inherited sharing class AsyncCalloutExecutor implements Queueable, Database.AllowsCallouts {
  @TestVisible
  private static final Integer DEFAULT_MAX_ATTEMPTS = 3;
  @TestVisible
  private static final Integer MAX_DELAY_MINUTES = 10;

  // Test seam: Apex tests cannot reliably chain Queueables, so when set, retries record
  // their delay here instead of being enqueued.
  @TestVisible
  private static List<Integer> retryDelaysMinutes;

  private final ICalloutQueueable callout;
  private final Integer maxAttempts;
  private Integer attempts = 0;

  public AsyncCalloutExecutor(ICalloutQueueable callout) {
    this(callout, DEFAULT_MAX_ATTEMPTS);
  }

  /**
   * @param maxAttempts Total runs allowed, including the first; must be at least 1.
   */
  public AsyncCalloutExecutor(ICalloutQueueable callout, Integer maxAttempts) {
    if (callout == null) {
      throw new BaseIntegrationHandler.IntegrationException(
        'Callout is required'
      );
    }
    if (maxAttempts == null || maxAttempts < 1) {
      throw new BaseIntegrationHandler.IntegrationException(
        'Max attempts must be at least 1'
      );
    }
    this.callout = callout;
    this.maxAttempts = maxAttempts;
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
    } catch (BaseIntegrationHandler.RateLimitException e) {
      if (!retryLater(e)) {
        callout.onFailure(e);
      }
    } catch (Exception e) {
      callout.onFailure(e);
    }
  }

  @TestVisible
  private Integer getAttempts() {
    return attempts;
  }

  private Boolean retryLater(BaseIntegrationHandler.RateLimitException e) {
    if (
      attempts >= maxAttempts ||
      Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()
    ) {
      return false;
    }
    Integer delayMinutes = toDelayMinutes(e.retryAfterSeconds);
    if (retryDelaysMinutes != null) {
      retryDelaysMinutes.add(delayMinutes);
    } else {
      enqueue(delayMinutes);
    }
    return true;
  }

  @TestVisible
  private static Integer toDelayMinutes(Integer retryAfterSeconds) {
    if (retryAfterSeconds == null || retryAfterSeconds <= 0) {
      return 0;
    }
    Integer minutes = (Integer) Math.ceil(retryAfterSeconds / 60.0);
    return Math.min(minutes, MAX_DELAY_MINUTES);
  }
}

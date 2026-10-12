/**
 * Unit of asynchronous callout work run by AsyncCalloutExecutor.
 *
 * Implementations hold everything needed to make the call (e.g. a handler and a request) and
 * are serialized with the Queueable, so all their state must be serializable. The executor
 * depends only on this interface, never on concrete handlers.
 */
public interface ICalloutQueueable {
  /**
   * Performs the callouts, then any DML (callouts cannot follow uncommitted DML).
   * A failure the executor's retry policy deems transient makes it run this again later,
   * so a repeated run must be safe.
   */
  void execute();

  /**
   * Called once when the work fails for good: a failure that is not retryable, or one that
   * remains after the last retry. Runs after all callouts, so DML such as logging is allowed.
   */
  void onFailure(Exception error);
}

/**
 * Integration entry points to Logger. Entries have Category 'Integration' and the integration's
 * name, so they can be filtered apart from general logs.
 *
 * Request headers are never logged because they may carry credentials; bodies only when asked
 * for, because they may carry personal or payment data.
 */
public without sharing class IntegrationLogger {
  /**
   * Logs one callout attempt: request sent, response received (or the error when there was no
   * response), status, duration and timestamp. Level is ERROR for an exception or a 5xx status,
   * WARN for 4xx and INFO otherwise.
   */
  public static void logCallout(
    String integrationName,
    HttpRequest request,
    HttpResponse response,
    Exception error,
    Long durationMs,
    Boolean includePayloads
  ) {
    Boolean withPayloads = includePayloads == true;
    String method = request?.getMethod();
    String endpoint = request?.getEndpoint();
    String message = method + ' ' + endpoint;
    if (response != null) {
      message += ' returned ' + response.getStatusCode();
      if (String.isNotBlank(response.getStatus())) {
        message += ' ' + response.getStatus();
      }
    } else if (error != null) {
      message += ' failed';
    }

    Logger.LogEntry entry = new Logger.LogEntry(
        levelFor(response, error),
        message
      )
      .setIntegration(integrationName)
      .setRequest(method, endpoint, withPayloads ? request?.getBody() : null)
      .setException(error)
      .setDurationMs(durationMs);
    if (response != null) {
      entry.setResponse(
        response.getStatusCode(),
        response.getStatus(),
        withPayloads ? response.getBody() : null
      );
    }
    Logger.log(entry);
  }

  /** Logs a failure that is not tied to a single callout, e.g. work that ran out of retries. */
  public static void logFailure(
    String integrationName,
    String message,
    Exception error
  ) {
    Logger.log(
      new Logger.LogEntry(LoggingLevel.ERROR, message)
        .setIntegration(integrationName)
        .setException(error)
    );
  }

  /** Logs a warning for the integration, e.g. a retry being scheduled. */
  public static void logWarning(String integrationName, String message) {
    Logger.log(
      new Logger.LogEntry(LoggingLevel.WARN, message)
        .setIntegration(integrationName)
    );
  }

  private static LoggingLevel levelFor(HttpResponse response, Exception error) {
    if (error != null || response == null) {
      return LoggingLevel.ERROR;
    }
    Integer statusCode = response.getStatusCode();
    if (statusCode >= 500) {
      return LoggingLevel.ERROR;
    }
    return statusCode >= 400 ? LoggingLevel.WARN : LoggingLevel.INFO;
  }
}

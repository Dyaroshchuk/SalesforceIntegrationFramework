/**
 * Application logger.
 *
 * Each entry is published as a Log_Event__e (Publish Immediately) and LogEventTrigger stores it
 * as a Log__c record. Because the event is published immediately:
 *  - entries survive a rollback, so the error that failed a transaction is still recorded;
 *  - logging is allowed between callouts, where DML is not.
 * Every entry also goes to the debug log. Each publish counts as one DML statement; when the
 * limit is spent, entries only go to the debug log. Logging never throws.
 *
 * This class is pinned to API 66.0 on purpose: from API 67 EventBus.publish runs in user mode
 * and fails for users without Create on Log_Event__e (e.g. Standard User), silently losing their
 * logs. Do not raise its API version unless publishing gets a system-mode option.
 *
 * Usage:
 *   Logger.info('Sync started');
 *   Logger.error('Sync failed', e);
 *   Logger.log(new Logger.LogEntry(LoggingLevel.WARN, 'Slow response').setCategory(Logger.LogCategory.INTEGRATION));
 */
public without sharing class Logger {
  /** Values of Log__c.Category__c. */
  public enum LogCategory {
    GENERAL,
    INTEGRATION
  }

  private static final Map<LogCategory, String> CATEGORY_VALUES = new Map<LogCategory, String>{
    LogCategory.GENERAL => 'General',
    LogCategory.INTEGRATION => 'Integration'
  };
  /** Values of Log__c.Level__c; other logging levels are stored as DEBUG. */
  private static final Set<LoggingLevel> STORED_LEVELS = new Set<LoggingLevel>{
    LoggingLevel.ERROR,
    LoggingLevel.WARN,
    LoggingLevel.INFO,
    LoggingLevel.DEBUG
  };
  private static final Set<String> LOGGER_CLASSES = new Set<String>{
    'Logger',
    'IntegrationLogger'
  };
  /** Framework classes skipped when looking for the code that caused a log entry. */
  private static final Set<String> FRAMEWORK_CLASSES = new Set<String>{
    'BaseIntegrationHandler',
    'ConfiguredIntegrationHandler',
    'AsyncCalloutExecutor'
  };
  private static final Map<String, Schema.SObjectField> EVENT_FIELDS = Log_Event__e.SObjectType.getDescribe()
    .fields.getMap();

  public static void debug(String message) {
    log(new LogEntry(LoggingLevel.DEBUG, message));
  }

  public static void info(String message) {
    log(new LogEntry(LoggingLevel.INFO, message));
  }

  public static void warn(String message) {
    log(new LogEntry(LoggingLevel.WARN, message));
  }

  public static void error(String message) {
    log(new LogEntry(LoggingLevel.ERROR, message));
  }

  public static void error(Exception error) {
    log(new LogEntry(LoggingLevel.ERROR, null).setException(error));
  }

  public static void error(String message, Exception error) {
    log(new LogEntry(LoggingLevel.ERROR, message).setException(error));
  }

  public static void log(LogEntry entry) {
    if (entry == null) {
      return;
    }
    try {
      Log_Event__e event = toEvent(entry);
      System.debug(
        entry.level,
        'LOG [' + event.Category__c + '] ' + (event.Message__c ?? '')
      );
      if (Limits.getDmlStatements() >= Limits.getLimitDmlStatements()) {
        System.debug(
          LoggingLevel.ERROR,
          'Logger: DML statement limit reached, entry not saved'
        );
        return;
      }
      Database.SaveResult result = EventBus.publish(event);
      if (!result.isSuccess()) {
        System.debug(
          LoggingLevel.ERROR,
          'Logger: entry not saved: ' + result.getErrors()
        );
      }
    } catch (Exception e) {
      System.debug(LoggingLevel.ERROR, 'Logger failed: ' + e.getMessage());
    }
  }

  private static Log_Event__e toEvent(LogEntry entry) {
    Request current = Request.getCurrent();
    Log_Event__e event = new Log_Event__e(
      Category__c = CATEGORY_VALUES.get(entry.category),
      Level__c = STORED_LEVELS.contains(entry.level)
        ? entry.level.name()
        : LoggingLevel.DEBUG.name(),
      Message__c = entry.message,
      Source__c = findSource(),
      Transaction_Id__c = current.getRequestId(),
      Quiddity__c = current.getQuiddity()?.name(),
      Author_Id__c = UserInfo.getUserId(),
      Timestamp__c = Datetime.now(),
      Integration_Name__c = entry.integrationName,
      Http_Method__c = entry.httpMethod,
      Endpoint__c = entry.endpoint,
      Request_Body__c = entry.requestBody,
      Status_Code__c = entry.statusCode,
      Status__c = entry.status,
      Response_Body__c = entry.responseBody,
      Duration_Ms__c = entry.durationMs
    );
    if (entry.error != null) {
      String errorMessage = entry.error.getMessage();
      event.Message__c = String.isBlank(entry.message)
        ? errorMessage
        : entry.message + ': ' + errorMessage;
      event.Exception_Type__c = entry.error.getTypeName();
      event.Stack_Trace__c = describeStackTrace(entry.error);
    }
    truncate(event);
    return event;
  }

  /** Stack trace of the exception followed by its causes. */
  private static String describeStackTrace(Exception error) {
    List<String> lines = new List<String>{ error.getStackTraceString() };
    Exception cause = error.getCause();
    while (cause != null) {
      lines.add(
        'Caused by: ' +
          cause.getTypeName() +
          ': ' +
          cause.getMessage() +
          '\n' +
          cause.getStackTraceString()
      );
      cause = cause.getCause();
    }
    return String.join(lines, '\n');
  }

  /**
   * The first stack frame outside the logger and the framework, e.g.
   * 'StripePaymentHandler.charge: line 42, column 1', or the first frame outside the logger when
   * the entry comes from the framework itself.
   */
  private static String findSource() {
    String frameworkFrame;
    for (String line : new DmlException().getStackTraceString().split('\n')) {
      String frame = line.removeStart('Class.');
      String className = frame.substringBefore('.');
      if (LOGGER_CLASSES.contains(className)) {
        continue;
      }
      if (!FRAMEWORK_CLASSES.contains(className)) {
        return frame;
      }
      frameworkFrame = frameworkFrame ?? frame;
    }
    return frameworkFrame;
  }

  private static void truncate(Log_Event__e event) {
    for (String fieldName : event.getPopulatedFieldsAsMap().keySet()) {
      Object value = event.get(fieldName);
      if (value instanceof String) {
        Integer maxLength = EVENT_FIELDS.get(fieldName)
          .getDescribe()
          .getLength();
        event.put(fieldName, ((String) value).abbreviate(maxLength));
      }
    }
  }

  /** One log entry; build it with the fluent setters and pass it to Logger.log(). */
  public class LogEntry {
    public LoggingLevel level { get; private set; }
    public LogCategory category { get; private set; }
    public String message { get; private set; }
    public Exception error { get; private set; }
    public String integrationName { get; private set; }
    public String httpMethod { get; private set; }
    public String endpoint { get; private set; }
    public String requestBody { get; private set; }
    public Integer statusCode { get; private set; }
    public String status { get; private set; }
    public String responseBody { get; private set; }
    public Long durationMs { get; private set; }

    public LogEntry(LoggingLevel level, String message) {
      this.level = level ?? LoggingLevel.DEBUG;
      this.message = message;
      this.category = LogCategory.GENERAL;
    }

    public LogEntry setCategory(LogCategory category) {
      this.category = category ?? LogCategory.GENERAL;
      return this;
    }

    /** Adds the exception's type and stack trace; its message is appended to the entry's. */
    public LogEntry setException(Exception error) {
      this.error = error;
      return this;
    }

    /** Marks the entry as an integration log for the given integration. */
    public LogEntry setIntegration(String integrationName) {
      this.integrationName = integrationName;
      this.category = LogCategory.INTEGRATION;
      return this;
    }

    public LogEntry setRequest(String httpMethod, String endpoint, String body) {
      this.httpMethod = httpMethod;
      this.endpoint = endpoint;
      this.requestBody = body;
      return this;
    }

    public LogEntry setResponse(Integer statusCode, String status, String body) {
      this.statusCode = statusCode;
      this.status = status;
      this.responseBody = body;
      return this;
    }

    public LogEntry setDurationMs(Long durationMs) {
      this.durationMs = durationMs;
      return this;
    }
  }
}

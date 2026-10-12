/**
 * Deletes Log__c records older than the retention period and empties them from the Recycle Bin,
 * so logs do not fill data storage.
 *
 * Usage:
 *   LogCleanupBatch.schedule();                          // daily at 02:00, 30 days retention
 *   Database.executeBatch(new LogCleanupBatch(7), 2000); // one-off run, 7 days retention
 *
 * Runs without sharing and in system mode because it must see and delete every user's logs,
 * whoever schedules it.
 */
public without sharing class LogCleanupBatch implements Database.Batchable<SObject>, Schedulable {
  @TestVisible
  private static final String JOB_NAME = 'Log Cleanup';
  @TestVisible
  private static final Integer DEFAULT_RETENTION_DAYS = 30;
  private static final String DAILY_AT_2AM = '0 0 2 * * ?';
  private static final Integer BATCH_SIZE = 2000;

  private final Integer retentionDays;

  public LogCleanupBatch() {
    this(DEFAULT_RETENTION_DAYS);
  }

  /** @param retentionDays Logs created more than this many days ago are deleted; at least 1. */
  public LogCleanupBatch(Integer retentionDays) {
    if (retentionDays == null || retentionDays < 1) {
      throw new IllegalArgumentException('Retention must be at least 1 day');
    }
    this.retentionDays = retentionDays;
  }

  /**
   * Schedules the daily cleanup with the default retention unless a job with the same name
   * already exists. Returns the CronTrigger Id of the new or existing job.
   */
  public static Id schedule() {
    List<CronTrigger> existing = [
      SELECT Id
      FROM CronTrigger
      WHERE CronJobDetail.Name = :JOB_NAME
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    if (!existing.isEmpty()) {
      return existing[0].Id;
    }
    return System.schedule(JOB_NAME, DAILY_AT_2AM, new LogCleanupBatch());
  }

  public void execute(SchedulableContext context) {
    Database.executeBatch(new LogCleanupBatch(retentionDays), BATCH_SIZE);
  }

  public Database.QueryLocator start(Database.BatchableContext context) {
    Datetime cutoff = Datetime.now().addDays(-retentionDays);
    return Database.getQueryLocator(
      [SELECT Id FROM Log__c WHERE CreatedDate < :cutoff WITH SYSTEM_MODE]
    );
  }

  public void execute(Database.BatchableContext context, List<Log__c> logs) {
    List<Database.DeleteResult> results = Database.delete(
      logs,
      false,
      AccessLevel.SYSTEM_MODE
    );
    List<Id> deletedIds = new List<Id>();
    for (Database.DeleteResult result : results) {
      if (result.isSuccess()) {
        deletedIds.add(result.getId());
      } else {
        Logger.warn('Log cleanup could not delete a log: ' + result.getErrors());
      }
    }
    if (!deletedIds.isEmpty()) {
      Database.emptyRecycleBin(deletedIds);
    }
  }

  public void finish(Database.BatchableContext context) {
  }
}

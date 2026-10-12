@IsTest
private class LogCleanupBatchTest {
  @IsTest
  static void deletesOnlyLogsOlderThanRetention() {
    List<Log__c> logs = new List<Log__c>{
      new Log__c(Message__c = 'old'),
      new Log__c(Message__c = 'at limit'),
      new Log__c(Message__c = 'recent')
    };
    insert as system logs;
    Test.setCreatedDate(logs[0].Id, Datetime.now().addDays(-31));
    Test.setCreatedDate(logs[1].Id, Datetime.now().addDays(-29));

    Test.startTest();
    Database.executeBatch(new LogCleanupBatch(30));
    Test.stopTest();

    List<Log__c> remaining = [
      SELECT Message__c
      FROM Log__c
      WITH SYSTEM_MODE
      ORDER BY Name
    ];
    Assert.areEqual(2, remaining.size());
    Assert.areEqual('at limit', remaining[0].Message__c);
    Assert.areEqual('recent', remaining[1].Message__c);
    // Recycle Bin purging is not observable in tests (ALL ROWS still returns the row).
    Assert.isTrue(
      [
        SELECT IsDeleted
        FROM Log__c
        WHERE Id = :logs[0].Id
        WITH SYSTEM_MODE
        ALL ROWS
      ]
      .IsDeleted
    );
  }

  @IsTest
  static void deletesBulkLogs() {
    TestDataFactory.insertLogs(200, Datetime.now().addDays(-60));
    TestDataFactory.insertLogs(5, null);

    Test.startTest();
    Database.executeBatch(new LogCleanupBatch(30));
    Test.stopTest();

    Assert.areEqual(5, [SELECT COUNT() FROM Log__c WITH SYSTEM_MODE]);
  }

  @IsTest
  static void scheduledRunStartsCleanup() {
    Log__c old = new Log__c(Message__c = 'old');
    insert as system old;
    Test.setCreatedDate(old.Id, Datetime.now().addDays(-40));

    Test.startTest();
    new LogCleanupBatch().execute((SchedulableContext) null);
    Test.stopTest();

    Assert.areEqual(0, [SELECT COUNT() FROM Log__c WITH SYSTEM_MODE]);
  }

  @IsTest
  static void scheduleIsIdempotent() {
    Test.startTest();
    Id jobId = LogCleanupBatch.schedule();
    Id secondJobId = LogCleanupBatch.schedule();
    Test.stopTest();

    Assert.areEqual(jobId, secondJobId);
    CronTrigger job = [
      SELECT CronExpression, CronJobDetail.Name
      FROM CronTrigger
      WHERE Id = :jobId
      WITH SYSTEM_MODE
    ];
    Assert.areEqual(LogCleanupBatch.JOB_NAME, job.CronJobDetail.Name);
    Assert.areEqual('0 0 2 * * ?', job.CronExpression);
  }

  @IsTest
  static void rejectsInvalidRetention() {
    for (Integer retentionDays : new List<Integer>{ null, 0, -5 }) {
      try {
        new LogCleanupBatch(retentionDays);
        Assert.fail('Expected IllegalArgumentException for ' + retentionDays);
      } catch (IllegalArgumentException e) {
        Assert.areEqual('Retention must be at least 1 day', e.getMessage());
      }
    }
  }
}

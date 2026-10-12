@IsTest
private class LoggerTest {
  @IsTest
  static void storesEntriesAtEachLevel() {
    Logger.debug('debug message');
    Logger.info('info message');
    Logger.warn('warn message');
    Logger.error('error message');

    List<Log__c> logs = deliverAndQuery();

    Assert.areEqual(4, logs.size());
    List<String> levels = new List<String>{ 'DEBUG', 'INFO', 'WARN', 'ERROR' };
    for (Integer i = 0; i < logs.size(); i++) {
      Log__c log = logs[i];
      Assert.areEqual(levels[i], log.Level__c);
      Assert.areEqual(levels[i].toLowerCase() + ' message', log.Message__c);
      Assert.areEqual('General', log.Category__c);
      Assert.areEqual(UserInfo.getUserId(), log.Author__c);
      Assert.isNotNull(log.Timestamp__c);
      Assert.isNotNull(log.Transaction_Id__c);
      Assert.isNotNull(log.Quiddity__c);
      Assert.isTrue(
        log.Source__c.startsWith('LoggerTest.storesEntriesAtEachLevel'),
        log.Source__c
      );
    }
  }

  @IsTest
  static void storesExceptionDetails() {
    try {
      throw new BaseIntegrationHandler.IntegrationException(
        'Sync failed',
        new CalloutException('Read timed out')
      );
    } catch (Exception e) {
      Logger.error('Order 42', e);
      Logger.error(e);
    }

    List<Log__c> logs = deliverAndQuery();

    Assert.areEqual(2, logs.size());
    Assert.areEqual('Order 42: Sync failed', logs[0].Message__c);
    Assert.areEqual('Sync failed', logs[1].Message__c);
    Assert.areEqual(
      'BaseIntegrationHandler.IntegrationException',
      logs[0].Exception_Type__c
    );
    Assert.isTrue(
      logs[0]
        .Stack_Trace__c.contains(
          'Caused by: System.CalloutException: Read timed out'
        ),
      logs[0].Stack_Trace__c
    );
  }

  @IsTest
  static void storesIntegrationEntries() {
    Logger.log(
      new Logger.LogEntry(LoggingLevel.FINE, 'Charge created')
        .setIntegration('Stripe')
        .setRequest('POST', 'callout:Stripe_API/v1/charges', '{"amount":100}')
        .setResponse(201, 'Created', '{"id":"ch_1"}')
        .setDurationMs(250)
    );

    Log__c log = deliverAndQuery()[0];

    Assert.areEqual('Integration', log.Category__c);
    // Levels without a picklist value are stored as DEBUG.
    Assert.areEqual('DEBUG', log.Level__c);
    Assert.areEqual('Stripe', log.Integration_Name__c);
    Assert.areEqual('POST', log.Http_Method__c);
    Assert.areEqual('callout:Stripe_API/v1/charges', log.Endpoint__c);
    Assert.areEqual('{"amount":100}', log.Request_Body__c);
    Assert.areEqual(201, log.Status_Code__c);
    Assert.areEqual('Created', log.Status__c);
    Assert.areEqual('{"id":"ch_1"}', log.Response_Body__c);
    Assert.areEqual(250, log.Duration_Ms__c);
  }

  @IsTest
  static void categoryCanBeSetExplicitly() {
    Logger.log(
      new Logger.LogEntry(LoggingLevel.WARN, 'Slow response')
        .setCategory(Logger.LogCategory.INTEGRATION)
    );
    Logger.log(new Logger.LogEntry(null, 'No level').setCategory(null));

    List<Log__c> logs = deliverAndQuery();

    Assert.areEqual('Integration', logs[0].Category__c);
    Assert.areEqual('General', logs[1].Category__c);
    Assert.areEqual('DEBUG', logs[1].Level__c);
  }

  @IsTest
  static void truncatesValuesToFieldLength() {
    Logger.log(
      new Logger.LogEntry(LoggingLevel.INFO, 'x'.repeat(40000))
        .setRequest('GET', 'callout:API/' + 'a'.repeat(300), null)
    );

    Log__c log = deliverAndQuery()[0];

    Assert.areEqual(32768, log.Message__c.length());
    Assert.isTrue(log.Message__c.endsWith('...'));
    Assert.areEqual(255, log.Endpoint__c.length());
  }

  @IsTest
  static void storesEntriesForStandardUsers() {
    User standardUser = TestDataFactory.insertStandardUser(null);

    System.runAs(standardUser) {
      Logger.error('Logged without log permissions');
    }

    List<Log__c> logs = deliverAndQuery();
    Assert.areEqual(1, logs.size());
    Assert.areEqual(standardUser.Id, logs[0].Author__c);
  }

  @IsTest
  static void storesBulkEvents() {
    List<Log_Event__e> events = new List<Log_Event__e>();
    for (Integer i = 0; i < 200; i++) {
      events.add(
        new Log_Event__e(
          Category__c = 'Integration',
          Level__c = 'INFO',
          Message__c = 'Event ' + i,
          Author_Id__c = UserInfo.getUserId()
        )
      );
    }

    Test.startTest();
    LogEventTriggerHandler.persist(events);
    Integer queries = Limits.getQueries();
    Integer dmlStatements = Limits.getDmlStatements();
    Test.stopTest();

    Assert.areEqual(
      200,
      [
        SELECT COUNT()
        FROM Log__c
        WHERE Category__c = 'Integration'
        WITH SYSTEM_MODE
      ]
    );
    Assert.areEqual(0, queries, 'No queries per event');
    Assert.areEqual(1, dmlStatements, 'One insert for the whole batch');
  }

  @IsTest
  static void ignoresNullEntry() {
    Logger.log(null);

    Assert.isTrue(deliverAndQuery().isEmpty());
  }

  @IsTest
  static void triggerSkipsInvalidAuthor() {
    LogEventTriggerHandler.persist(
      new List<Log_Event__e>{
        new Log_Event__e(Level__c = 'INFO', Author_Id__c = 'not an id'),
        new Log_Event__e(Level__c = 'INFO', Author_Id__c = '001000000000000AAA')
      }
    );

    for (Log__c log : [SELECT Author__c FROM Log__c WITH SYSTEM_MODE]) {
      Assert.isNull(log.Author__c);
    }
  }

  private static List<Log__c> deliverAndQuery() {
    Test.getEventBus().deliver();
    return [
      SELECT
        Category__c,
        Level__c,
        Message__c,
        Exception_Type__c,
        Stack_Trace__c,
        Source__c,
        Transaction_Id__c,
        Quiddity__c,
        Author__c,
        Timestamp__c,
        Integration_Name__c,
        Http_Method__c,
        Endpoint__c,
        Request_Body__c,
        Status_Code__c,
        Status__c,
        Response_Body__c,
        Duration_Ms__c
      FROM Log__c
      WITH SYSTEM_MODE
      ORDER BY Name
    ];
  }
}

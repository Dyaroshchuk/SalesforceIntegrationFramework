@IsTest
private class IntegrationConfigLoaderTest {
  private static final String NAMED_CREDENTIAL = 'Test_API';

  @IsTest
  static void loadsAllFields() {
    Integration_Configuration__mdt record = record('Billing');
    record.MasterLabel = 'Billing API';
    record.Base_Path__c = 'v1/';
    record.Timeout_Seconds__c = 15;
    record.Max_Retries__c = 3;
    record.Retry_Delay_Ms__c = 500;
    record.Retryable_Status_Codes__c = '502, 503';
    record.Max_Callouts_Per_Transaction__c = 10;
    record.Default_Retry_After_Seconds__c = 30;
    record.Default_Headers__c = '{"X-Api-Version":"2024-06-20"}';
    record.Field_Mappings__c = '{"Email":"email","Company":"company"}';
    record.Additional_Settings__c = '{"conflictResolution":"salesforceWins","batchSize":50}';
    record.Logging_Enabled__c = true;
    record.Log_Payloads__c = true;
    setUp(record);

    IntegrationConfigLoader.IntegrationConfig config = IntegrationConfigLoader.load(
      'Billing'
    );

    Assert.areEqual('Billing', config.integrationName);
    Assert.areEqual('Billing API', config.label);
    Assert.areEqual(NAMED_CREDENTIAL, config.namedCredential);
    Assert.areEqual('callout:Test_API/v1', config.baseEndpoint);
    Assert.areEqual(15000, config.timeoutMs);
    Assert.areEqual(3, config.maxRetries);
    Assert.areEqual(500, config.retryDelayMs);
    Assert.areEqual(new Set<Integer>{ 502, 503 }, config.retryableStatusCodes);
    Assert.areEqual(10, config.maxCalloutsPerTransaction);
    Assert.areEqual(30, config.defaultRetryAfterSeconds);
    Assert.areEqual(
      new Map<String, String>{ 'X-Api-Version' => '2024-06-20' },
      config.defaultHeaders
    );
    Assert.areEqual(
      new Map<String, String>{ 'Email' => 'email', 'Company' => 'company' },
      config.fieldMappings
    );
    Assert.areEqual('salesforceWins', config.getSetting('conflictResolution'));
    Assert.areEqual(50, config.getSetting('batchSize'));
    Assert.isNull(config.getSetting('missing'));
    Assert.isTrue(config.loggingEnabled);
    Assert.isTrue(config.logPayloads);
  }

  @IsTest
  static void leavesBlankOptionalFieldsNull() {
    setUp(record('Billing'));

    IntegrationConfigLoader.IntegrationConfig config = IntegrationConfigLoader.load(
      'Billing'
    );

    Assert.areEqual('callout:Test_API', config.baseEndpoint);
    Assert.isNull(config.timeoutMs);
    Assert.isNull(config.maxRetries);
    Assert.isNull(config.retryDelayMs);
    Assert.isNull(config.retryableStatusCodes);
    Assert.isNull(config.maxCalloutsPerTransaction);
    Assert.isNull(config.defaultRetryAfterSeconds);
    Assert.isTrue(config.defaultHeaders.isEmpty());
    Assert.isTrue(config.fieldMappings.isEmpty());
    Assert.isTrue(config.settings.isEmpty());
  }

  @IsTest
  static void lookupIsCaseInsensitiveAndCached() {
    setUp(record('Billing'));

    IntegrationConfigLoader.IntegrationConfig config = IntegrationConfigLoader.load(
      'billing'
    );

    Assert.areEqual('Billing', config.integrationName);
    Assert.isTrue(config === IntegrationConfigLoader.load('BILLING'));
  }

  @IsTest
  static void acceptsNamedCredentialWithCalloutPrefix() {
    Integration_Configuration__mdt record = record('Billing');
    record.Named_Credential__c = 'callout:' + NAMED_CREDENTIAL;
    setUp(record);

    Assert.areEqual(
      'callout:Test_API',
      IntegrationConfigLoader.load('Billing').baseEndpoint
    );
  }

  @IsTest
  static void throwsWhenRecordIsMissing() {
    setUp(record('Billing'));

    assertLoadFails('Shipping', 'No Integration_Configuration__mdt record found');
    assertLoadFails(' ', 'Integration name is required');
  }

  @IsTest
  static void throwsWhenRecordIsInactive() {
    Integration_Configuration__mdt record = record('Billing');
    record.Is_Active__c = false;
    setUp(record);

    assertLoadFails('Billing', 'Integration Billing is not active');
    Assert.isFalse(IntegrationConfigLoader.isActive('Billing'));
  }

  @IsTest
  static void isActiveChecksForAnActiveRecord() {
    setUp(record('Billing'));

    Assert.isTrue(IntegrationConfigLoader.isActive('billing'));
    Assert.isFalse(IntegrationConfigLoader.isActive('Shipping'));
    Assert.isFalse(IntegrationConfigLoader.isActive(null));
  }

  @IsTest
  static void throwsWhenNamedCredentialDoesNotExist() {
    Integration_Configuration__mdt record = record('Billing');
    record.Named_Credential__c = 'Unknown_API';
    setUp(record);

    assertLoadFails('Billing', 'Named Credential Unknown_API does not exist');
  }

  @IsTest
  static void reportsEveryValidationError() {
    Integration_Configuration__mdt record = record('Billing');
    record.Named_Credential__c = null;
    record.Base_Path__c = 'https://api.example.com/v1';
    record.Timeout_Seconds__c = 121;
    record.Max_Retries__c = -1;
    record.Max_Callouts_Per_Transaction__c = 0;
    record.Retryable_Status_Codes__c = '503,abc,700';
    record.Default_Headers__c = '{"Authorization":"Bearer secret","X-Count":5}';
    record.Field_Mappings__c = '["Email"]';
    record.Additional_Settings__c = '{not json';
    setUp(record);

    String message = assertLoadFails(
      'Billing',
      'Invalid configuration for integration Billing'
    );

    for (
      String expected : new List<String>{
        'Named_Credential__c is required',
        'Base_Path__c must be a path',
        'Timeout_Seconds__c must be between 1 and 120',
        'Max_Retries__c must be at least 0',
        'Max_Callouts_Per_Transaction__c must be at least 1',
        'invalid status code: abc',
        'invalid status code: 700',
        'must not contain Authorization',
        'Default_Headers__c value for "X-Count" must be a string',
        'Field_Mappings__c must be a JSON object',
        'Additional_Settings__c must be a JSON object'
      }
    ) {
      Assert.isTrue(message.contains(expected), 'Missing "' + expected + '" in: ' + message);
    }
  }

  @IsTest
  static void configurationExceptionIsAnIntegrationException() {
    setUp(record('Billing'));

    try {
      IntegrationConfigLoader.load('Shipping');
      Assert.fail('Expected an exception');
    } catch (BaseIntegrationHandler.IntegrationException e) {
      Assert.isInstanceOfType(e, IntegrationConfigLoader.ConfigurationException.class);
    }
  }

  /** Runs the real queries; the org has no configuration records or matching credential. */
  @IsTest
  static void readsRecordsAndNamedCredentialsFromTheOrg() {
    assertLoadFails('Not_Configured_Integration', 'No Integration_Configuration__mdt record found');

    Integration_Configuration__mdt record = record('Billing');
    record.Named_Credential__c = 'Not_A_Real_Named_Credential';
    IntegrationConfigLoader.setRecords(new List<Integration_Configuration__mdt>{ record });

    assertLoadFails('Billing', 'Named Credential Not_A_Real_Named_Credential does not exist');
  }

  private static Integration_Configuration__mdt record(String developerName) {
    return new Integration_Configuration__mdt(
      DeveloperName = developerName,
      MasterLabel = developerName,
      Is_Active__c = true,
      Named_Credential__c = NAMED_CREDENTIAL
    );
  }

  private static void setUp(Integration_Configuration__mdt record) {
    IntegrationConfigLoader.setRecords(new List<Integration_Configuration__mdt>{ record });
    IntegrationConfigLoader.setNamedCredentialNames(new Set<String>{ NAMED_CREDENTIAL });
  }

  private static String assertLoadFails(String integrationName, String expectedMessage) {
    try {
      IntegrationConfigLoader.load(integrationName);
    } catch (IntegrationConfigLoader.ConfigurationException e) {
      Assert.isTrue(
        e.getMessage().contains(expectedMessage),
        'Unexpected message: ' + e.getMessage()
      );
      return e.getMessage();
    }
    Assert.fail('Expected a ConfigurationException for ' + integrationName);
    return null;
  }
}

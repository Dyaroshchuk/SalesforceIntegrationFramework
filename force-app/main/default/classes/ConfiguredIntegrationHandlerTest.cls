@IsTest
private class ConfiguredIntegrationHandlerTest {
  private static final String INTEGRATION_NAME = 'Billing';
  private static final String NAMED_CREDENTIAL = 'Billing_API';

  // Statics are reset for every test method, so each test gets a fresh mock.
  private static fflib_ApexMocks mocks = new fflib_ApexMocks();
  private static IntegrationHttpClient client = (IntegrationHttpClient) mocks.mock(
    IntegrationHttpClient.class
  );

  @IsTest
  static void usesConfiguredEndpointHeadersAndRetryPolicy() {
    Integration_Configuration__mdt record = record();
    record.Base_Path__c = '/v1';
    record.Timeout_Seconds__c = 10;
    record.Max_Retries__c = 1;
    record.Retryable_Status_Codes__c = '409';
    record.Max_Callouts_Per_Transaction__c = 5;
    record.Default_Retry_After_Seconds__c = 15;
    record.Default_Headers__c = '{"X-Api-Version":"2","Accept":"application/vnd.billing+json"}';
    setUp(record);
    mocks.startStubbing();
    mocks.when(client.send(anyRequest()))
      .thenReturn(response(409))
      .thenReturn(response(503));
    mocks.stopStubbing();
    TestHandler handler = new TestHandler(client);

    BaseIntegrationHandler.IntegrationResponse result = handler.execute(
      new BaseIntegrationHandler.IntegrationRequest('GET', 'invoices')
    );

    // 409 is retried once (Max_Retries__c = 1); 503 is not in the configured codes anyway.
    Assert.areEqual(503, result.statusCode);
    Assert.areEqual(2, result.attempts);
    HttpRequest sent = sentRequests(2)[0];
    Assert.areEqual('callout:Billing_API/v1/invoices', sent.getEndpoint());
    Assert.areEqual('2', sent.getHeader('X-Api-Version'));
    Assert.areEqual('application/vnd.billing+json', sent.getHeader('Accept'));
    Assert.areEqual('application/json', sent.getHeader('Content-Type'));
    Assert.areEqual(10000, handler.timeoutMs());
    Assert.areEqual(5, handler.maxCalloutsPerTransaction());
    Assert.areEqual(15, handler.defaultRetryAfterSeconds());
  }

  @IsTest
  static void fallsBackToFrameworkDefaultsForBlankFields() {
    setUp(record());
    mocks.startStubbing();
    mocks.when(client.send(anyRequest()))
      .thenReturn(response(503))
      .thenReturn(response(502))
      .thenReturn(response(200));
    mocks.stopStubbing();
    TestHandler handler = new TestHandler(client);

    BaseIntegrationHandler.IntegrationResponse result = handler.execute(
      new BaseIntegrationHandler.IntegrationRequest('GET', 'invoices')
    );

    Assert.isTrue(result.isSuccess());
    Assert.areEqual(3, result.attempts);
    HttpRequest sent = sentRequests(3)[0];
    Assert.areEqual('callout:Billing_API/invoices', sent.getEndpoint());
    Assert.areEqual('application/json', sent.getHeader('Accept'));
    Assert.areEqual(30000, handler.timeoutMs());
    Assert.isNull(handler.maxCalloutsPerTransaction());
    Assert.areEqual(60, handler.defaultRetryAfterSeconds());
  }

  @IsTest
  static void executeFailsWithoutActiveConfiguration() {
    Integration_Configuration__mdt record = record();
    record.Is_Active__c = false;
    setUp(record);

    try {
      new TestHandler(client)
        .execute(new BaseIntegrationHandler.IntegrationRequest('GET', 'invoices'));
      Assert.fail('Expected a ConfigurationException');
    } catch (IntegrationConfigLoader.ConfigurationException e) {
      Assert.areEqual('Integration Billing is not active', e.getMessage());
    }
    ((IntegrationHttpClient) mocks.verify(client, 0)).send(anyRequest());
  }

  @IsTest
  static void logsCalloutsButNeverTokenPayloads() {
    Integration_Configuration__mdt record = record();
    record.Logging_Enabled__c = true;
    record.Log_Payloads__c = true;
    setUp(record);
    mocks.startStubbing();
    mocks.when(client.send(anyRequest()))
      .thenReturn(response(200))
      .thenReturn(response(201));
    mocks.stopStubbing();

    new TokenHandler(client)
      .execute(
        new BaseIntegrationHandler.IntegrationRequest('POST', 'invoices')
          .setBody('{"amount":100}')
      );
    Test.getEventBus().deliver();

    List<Log__c> logs = [
      SELECT Category__c, Integration_Name__c, Endpoint__c, Status_Code__c, Request_Body__c
      FROM Log__c
      WITH SYSTEM_MODE
      ORDER BY Name
    ];
    Assert.areEqual(2, logs.size());
    Assert.areEqual('callout:Billing_API/oauth/token', logs[0].Endpoint__c);
    Assert.isNull(logs[0].Request_Body__c, 'Token credentials must not be logged');
    Assert.areEqual('callout:Billing_API/invoices', logs[1].Endpoint__c);
    Assert.areEqual('{"amount":100}', logs[1].Request_Body__c);
    Assert.areEqual(201, logs[1].Status_Code__c);
    for (Log__c log : logs) {
      Assert.areEqual('Integration', log.Category__c);
      Assert.areEqual(INTEGRATION_NAME, log.Integration_Name__c);
    }
  }

  @IsTest
  static void doesNotLogWhenLoggingIsDisabled() {
    Integration_Configuration__mdt record = record();
    record.Logging_Enabled__c = false;
    setUp(record);
    mocks.startStubbing();
    mocks.when(client.send(anyRequest())).thenReturn(response(200));
    mocks.stopStubbing();

    new TestHandler(client)
      .execute(new BaseIntegrationHandler.IntegrationRequest('GET', 'invoices'));
    Test.getEventBus().deliver();

    Assert.areEqual(0, [SELECT COUNT() FROM Log__c WITH SYSTEM_MODE]);
  }

  private static Integration_Configuration__mdt record() {
    return new Integration_Configuration__mdt(
      DeveloperName = INTEGRATION_NAME,
      MasterLabel = INTEGRATION_NAME,
      Is_Active__c = true,
      Named_Credential__c = NAMED_CREDENTIAL
    );
  }

  private static void setUp(Integration_Configuration__mdt record) {
    IntegrationConfigLoader.setRecords(new List<Integration_Configuration__mdt>{ record });
    IntegrationConfigLoader.setNamedCredentialNames(new Set<String>{ NAMED_CREDENTIAL });
  }

  private static HttpRequest anyRequest() {
    return (HttpRequest) fflib_Match.anyObject();
  }

  private static HttpResponse response(Integer statusCode) {
    HttpResponse httpResponse = new HttpResponse();
    httpResponse.setStatusCode(statusCode);
    return httpResponse;
  }

  /** Verifies the client was called exactly the given number of times and returns the requests. */
  private static List<HttpRequest> sentRequests(Integer times) {
    fflib_ArgumentCaptor captor = fflib_ArgumentCaptor.forClass(
      HttpRequest.class
    );
    ((IntegrationHttpClient) mocks.verify(client, times))
      .send((HttpRequest) captor.capture());

    List<HttpRequest> requests = new List<HttpRequest>();
    for (Object request : captor.getAllValues()) {
      requests.add((HttpRequest) request);
    }
    return requests;
  }

  /** HttpRequest has no timeout getter, so the resolved settings are exposed directly. */
  private class TestHandler extends ConfiguredIntegrationHandler {
    public TestHandler(IntegrationHttpClient httpClient) {
      setHttpClient(httpClient);
    }

    protected override String getIntegrationName() {
      return INTEGRATION_NAME;
    }

    public Integer timeoutMs() {
      return getTimeoutMs();
    }

    public Integer maxCalloutsPerTransaction() {
      return getMaxCalloutsPerTransaction();
    }

    public Integer defaultRetryAfterSeconds() {
      return getDefaultRetryAfterSeconds();
    }
  }

  /** Fetches a token through send() with credentials in the body. */
  private class TokenHandler extends ConfiguredIntegrationHandler {
    public TokenHandler(IntegrationHttpClient httpClient) {
      setHttpClient(httpClient);
    }

    protected override String getIntegrationName() {
      return INTEGRATION_NAME;
    }

    protected override BaseIntegrationHandler.AccessToken requestAccessToken() {
      HttpRequest tokenRequest = new HttpRequest();
      tokenRequest.setMethod('POST');
      tokenRequest.setEndpoint(getBaseEndpoint() + '/oauth/token');
      tokenRequest.setBody('client_secret=s3cret');
      send(tokenRequest);
      return new BaseIntegrationHandler.AccessToken('token', null, 3600);
    }
  }
}

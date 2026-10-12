@IsTest
private class IntegrationLoggerTest {
  private static final String ENDPOINT = 'callout:Billing_API/v1/invoices';

  @IsTest
  static void logsCalloutWithoutPayloadsByDefault() {
    IntegrationLogger.logCallout(
      'Billing',
      request('{"amount":100}'),
      response(200, 'OK', '{"id":"inv_1"}'),
      null,
      120,
      false
    );

    Log__c log = deliverAndQuery()[0];

    Assert.areEqual('Integration', log.Category__c);
    Assert.areEqual('INFO', log.Level__c);
    Assert.areEqual('Billing', log.Integration_Name__c);
    Assert.areEqual('POST', log.Http_Method__c);
    Assert.areEqual(ENDPOINT, log.Endpoint__c);
    Assert.areEqual(200, log.Status_Code__c);
    Assert.areEqual('OK', log.Status__c);
    Assert.areEqual(120, log.Duration_Ms__c);
    Assert.areEqual('POST ' + ENDPOINT + ' returned 200 OK', log.Message__c);
    Assert.isNull(log.Request_Body__c);
    Assert.isNull(log.Response_Body__c);
  }

  @IsTest
  static void logsPayloadsWhenRequested() {
    IntegrationLogger.logCallout(
      'Billing',
      request('{"amount":100}'),
      response(201, null, '{"id":"inv_1"}'),
      null,
      120,
      true
    );

    Log__c log = deliverAndQuery()[0];

    Assert.areEqual('{"amount":100}', log.Request_Body__c);
    Assert.areEqual('{"id":"inv_1"}', log.Response_Body__c);
    Assert.areEqual('POST ' + ENDPOINT + ' returned 201', log.Message__c);
  }

  @IsTest
  static void levelFollowsOutcome() {
    IntegrationLogger.logCallout('Billing', request(null), response(404, 'Not Found', ''), null, 1, false);
    IntegrationLogger.logCallout('Billing', request(null), response(503, 'Service Unavailable', ''), null, 1, false);
    IntegrationLogger.logCallout('Billing', request(null), null, new CalloutException('Read timed out'), 1, false);

    List<Log__c> logs = deliverAndQuery();

    Assert.areEqual('WARN', logs[0].Level__c);
    Assert.areEqual('ERROR', logs[1].Level__c);
    Assert.areEqual('ERROR', logs[2].Level__c);
    Assert.areEqual(
      'POST ' + ENDPOINT + ' failed: Read timed out',
      logs[2].Message__c
    );
    Assert.areEqual('System.CalloutException', logs[2].Exception_Type__c);
    Assert.isNull(logs[2].Status_Code__c);
  }

  @IsTest
  static void logsFailuresAndWarnings() {
    IntegrationLogger.logFailure(
      'Billing',
      'Sync gave up',
      new BaseIntegrationHandler.RateLimitException('Rate limited')
    );
    IntegrationLogger.logWarning('Billing', 'Retrying in 2 minute(s)');

    List<Log__c> logs = deliverAndQuery();

    Assert.areEqual('ERROR', logs[0].Level__c);
    Assert.areEqual('Sync gave up: Rate limited', logs[0].Message__c);
    Assert.areEqual('WARN', logs[1].Level__c);
    Assert.areEqual('Integration', logs[1].Category__c);
    Assert.areEqual('Billing', logs[1].Integration_Name__c);
  }

  private static HttpRequest request(String body) {
    HttpRequest httpRequest = new HttpRequest();
    httpRequest.setMethod('POST');
    httpRequest.setEndpoint(ENDPOINT);
    if (body != null) {
      httpRequest.setBody(body);
    }
    return httpRequest;
  }

  private static HttpResponse response(
    Integer statusCode,
    String status,
    String body
  ) {
    HttpResponse httpResponse = new HttpResponse();
    httpResponse.setStatusCode(statusCode);
    if (status != null) {
      httpResponse.setStatus(status);
    }
    httpResponse.setBody(body);
    return httpResponse;
  }

  private static List<Log__c> deliverAndQuery() {
    Test.getEventBus().deliver();
    return [
      SELECT
        Category__c,
        Level__c,
        Message__c,
        Exception_Type__c,
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

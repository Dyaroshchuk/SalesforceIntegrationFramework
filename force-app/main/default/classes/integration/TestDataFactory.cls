/**
 * Builds test data shared by the framework's test classes: HTTP responses, integration
 * configuration, users and log records.
 */
@IsTest
public class TestDataFactory {
  public static HttpResponse httpResponse(Integer statusCode) {
    return httpResponse(statusCode, null, null);
  }

  public static HttpResponse httpResponse(Integer statusCode, String body) {
    return httpResponse(statusCode, null, body);
  }

  public static HttpResponse httpResponse(
    Integer statusCode,
    String status,
    String body
  ) {
    HttpResponse response = new HttpResponse();
    response.setStatusCode(statusCode);
    if (status != null) {
      response.setStatus(status);
    }
    if (body != null) {
      response.setBody(body);
    }
    return response;
  }

  /** An active configuration record; custom metadata cannot be inserted, so it stays in memory. */
  public static Integration_Configuration__mdt integrationConfig(
    String integrationName,
    String namedCredential
  ) {
    return new Integration_Configuration__mdt(
      DeveloperName = integrationName,
      MasterLabel = integrationName,
      Is_Active__c = true,
      Named_Credential__c = namedCredential
    );
  }

  /** Makes IntegrationConfigLoader use the given record and treat its Named Credential as existing. */
  public static void useIntegrationConfig(
    Integration_Configuration__mdt record
  ) {
    IntegrationConfigLoader.setRecords(
      new List<Integration_Configuration__mdt>{ record }
    );
    IntegrationConfigLoader.setNamedCredentialNames(
      new Set<String>{ record.Named_Credential__c }
    );
  }

  /** Inserts a Standard User, with the permission set assigned when a name is given. */
  public static User insertStandardUser(String permissionSetName) {
    User user = new User(
      ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1]
      .Id,
      LastName = 'Test User',
      Email = 'framework.test@example.com',
      Username = 'framework.test.' +
        System.currentTimeMillis() +
        '.' +
        Crypto.getRandomInteger() +
        '@example.com',
      Alias = 'fwtest',
      TimeZoneSidKey = 'GMT',
      LocaleSidKey = 'en_US',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US'
    );
    insert user;
    if (permissionSetName != null) {
      insert new PermissionSetAssignment(
        AssigneeId = user.Id,
        PermissionSetId = [
          SELECT Id
          FROM PermissionSet
          WHERE Name = :permissionSetName
        ]
        .Id
      );
    }
    return user;
  }

  /** Inserts log records, back-dating their CreatedDate when one is given. */
  public static List<Log__c> insertLogs(Integer count, Datetime createdDate) {
    List<Log__c> logs = new List<Log__c>();
    for (Integer i = 0; i < count; i++) {
      logs.add(new Log__c(Level__c = 'INFO', Message__c = 'Log ' + i));
    }
    insert as system logs;
    if (createdDate != null) {
      for (Log__c log : logs) {
        Test.setCreatedDate(log.Id, createdDate);
      }
    }
    return logs;
  }
}

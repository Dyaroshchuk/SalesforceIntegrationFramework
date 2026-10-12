/**
 * Verifies the access the Integration User and Integration Admin permission sets grant, since the
 * framework queries its configuration in user mode.
 */
@IsTest
private class IntegrationPermissionSetsTest {
  @IsTest
  static void standardUserCannotReadConfigurationWithoutPermissionSet() {
    System.runAs(TestDataFactory.insertStandardUser(null)) {
      Assert.isFalse(
        Integration_Configuration__mdt.SObjectType.getDescribe().isAccessible()
      );
      try {
        IntegrationConfigLoader.load('Billing');
        Assert.fail('Expected a ConfigurationException');
      } catch (IntegrationConfigLoader.ConfigurationException e) {
        Assert.isTrue(
          e.getMessage().contains('Integration User permission set'),
          e.getMessage()
        );
      }
    }
  }

  @IsTest
  static void integrationUserCanReadConfigurationAndPublishLogs() {
    System.runAs(TestDataFactory.insertStandardUser('Integration_User')) {
      Assert.isTrue(
        Integration_Configuration__mdt.SObjectType.getDescribe().isAccessible()
      );
      Assert.isTrue(Log_Event__e.SObjectType.getDescribe().isCreateable());
      // Named Credentials are visible without extra permissions, for the existence check.
      Assert.isTrue(NamedCredential.SObjectType.getDescribe().isAccessible());
      // The org may have no records; the query itself must be allowed.
      try {
        IntegrationConfigLoader.load('Not_Configured_Integration');
        Assert.fail('Expected a ConfigurationException');
      } catch (IntegrationConfigLoader.ConfigurationException e) {
        Assert.isTrue(
          e.getMessage()
            .startsWith('No Integration_Configuration__mdt record found'),
          e.getMessage()
        );
      }
    }
  }

  @IsTest
  static void integrationAdminCanManageCredentialsConfigurationAndLogs() {
    PermissionSet admin = [
      SELECT PermissionsManageNamedCredentials, PermissionsCustomizeApplication
      FROM PermissionSet
      WHERE Name = 'Integration_Admin'
    ];
    Assert.isTrue(admin.PermissionsManageNamedCredentials);
    Assert.isTrue(admin.PermissionsCustomizeApplication);

    System.runAs(TestDataFactory.insertStandardUser('Integration_Admin')) {
      Assert.isTrue(
        Integration_Configuration__mdt.SObjectType.getDescribe().isAccessible()
      );
      Assert.isTrue(Log__c.SObjectType.getDescribe().isAccessible());
      Assert.isTrue(
        Log__c.Response_Body__c.getDescribe().isAccessible(),
        'Admins read every log field'
      );
    }
  }
}

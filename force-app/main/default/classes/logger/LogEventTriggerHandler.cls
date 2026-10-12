/**
 * Stores published Log_Event__e messages as Log__c records. Fields are copied by API name, so a
 * field added to both objects is stored without code changes. Author_Id__c becomes the Author__c
 * lookup, because records are created by the Automated Process user.
 */
public without sharing class LogEventTriggerHandler {
  private static final Set<String> LOG_FIELDS = Log__c.SObjectType.getDescribe()
    .fields.getMap()
    .keySet();

  public static void persist(List<Log_Event__e> events) {
    List<Log__c> logs = new List<Log__c>();
    for (Log_Event__e event : events) {
      Log__c log = new Log__c();
      Map<String, Object> values = event.getPopulatedFieldsAsMap();
      for (String fieldName : values.keySet()) {
        if (
          fieldName.endsWithIgnoreCase('__c') &&
          LOG_FIELDS.contains(fieldName.toLowerCase())
        ) {
          log.put(fieldName, values.get(fieldName));
        }
      }
      log.Author__c = toUserId(event.Author_Id__c);
      logs.add(log);
    }

    // Partial success: one invalid entry must not lose the rest of the batch.
    List<Database.SaveResult> results = Database.insert(
      logs,
      false,
      AccessLevel.SYSTEM_MODE
    );
    for (Database.SaveResult result : results) {
      if (!result.isSuccess()) {
        System.debug(
          LoggingLevel.ERROR,
          'Log entry not stored: ' + result.getErrors()
        );
      }
    }
  }

  private static Id toUserId(String value) {
    if (String.isBlank(value) || !(((Object) value) instanceof Id)) {
      return null;
    }
    Id userId = (Id) value;
    return userId.getSObjectType() == User.SObjectType ? userId : null;
  }
}

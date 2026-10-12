/**
 * Loads the configuration of an integration from two sources:
 *  - Named Credential: endpoint host and authentication, encrypted and managed by Salesforce.
 *  - Integration_Configuration__mdt: behaviour (timeout, retry policy, headers, field mappings,
 *    flags), deployable and version controlled. The record's DeveloperName is the integration name.
 *
 * All records are read with a single query and cached for the transaction, as are the names of the
 * org's Named Credentials. A query is used instead of getInstance()/getAll() because those truncate
 * long text fields to 255 characters.
 *
 * Every record is validated when loaded; all problems are reported in one ConfigurationException.
 */
public inherited sharing class IntegrationConfigLoader {
  private static final String CALLOUT_PREFIX = 'callout:';
  private static final Integer MAX_TIMEOUT_SECONDS = 120;
  private static final Set<String> FORBIDDEN_HEADERS = new Set<String>{
    'authorization',
    'proxy-authorization',
    'cookie'
  };

  // Transaction-scoped caches, keyed by lower-cased name.
  private static Map<String, Integration_Configuration__mdt> recordsByName;
  private static Set<String> namedCredentialNames;
  private static Map<String, IntegrationConfig> configs = new Map<String, IntegrationConfig>();

  /**
   * Returns the validated configuration of an active integration. Lookup is case-insensitive.
   *
   * @throws ConfigurationException when no active record exists or the record is invalid.
   */
  public static IntegrationConfig load(String integrationName) {
    if (String.isBlank(integrationName)) {
      throw new ConfigurationException('Integration name is required');
    }
    String key = integrationName.toLowerCase();
    IntegrationConfig config = configs.get(key);
    if (config == null) {
      Integration_Configuration__mdt record = getRecordsByName().get(key);
      if (record == null) {
        throw new ConfigurationException(
          'No Integration_Configuration__mdt record found for ' + integrationName
        );
      }
      if (!record.Is_Active__c) {
        throw new ConfigurationException(
          'Integration ' + record.DeveloperName + ' is not active'
        );
      }
      config = new IntegrationConfig(record);
      configs.put(key, config);
    }
    return config;
  }

  /** True when an active configuration record exists; does not validate it. */
  public static Boolean isActive(String integrationName) {
    Integration_Configuration__mdt record = String.isBlank(integrationName)
      ? null
      : getRecordsByName().get(integrationName.toLowerCase());
    return record != null && record.Is_Active__c;
  }

  /** Replaces the configuration records, since custom metadata cannot be inserted in tests. */
  @TestVisible
  private static void setRecords(List<Integration_Configuration__mdt> records) {
    recordsByName = new Map<String, Integration_Configuration__mdt>();
    for (Integration_Configuration__mdt record : records) {
      recordsByName.put(record.DeveloperName.toLowerCase(), record);
    }
    configs.clear();
  }

  /** Replaces the org's Named Credential names, since Named Credentials cannot be created in tests. */
  @TestVisible
  private static void setNamedCredentialNames(Set<String> names) {
    namedCredentialNames = new Set<String>();
    for (String name : names) {
      namedCredentialNames.add(name.toLowerCase());
    }
    configs.clear();
  }

  private static Map<String, Integration_Configuration__mdt> getRecordsByName() {
    if (recordsByName == null) {
      setRecords(
        [
          SELECT
            DeveloperName,
            MasterLabel,
            Is_Active__c,
            Named_Credential__c,
            Base_Path__c,
            Timeout_Seconds__c,
            Max_Retries__c,
            Retry_Delay_Ms__c,
            Retryable_Status_Codes__c,
            Max_Callouts_Per_Transaction__c,
            Default_Retry_After_Seconds__c,
            Default_Headers__c,
            Field_Mappings__c,
            Additional_Settings__c,
            Logging_Enabled__c,
            Log_Payloads__c
          FROM Integration_Configuration__mdt
        ]
      );
    }
    return recordsByName;
  }

  private static Boolean namedCredentialExists(String name) {
    if (namedCredentialNames == null) {
      Set<String> names = new Set<String>();
      for (NamedCredential credential : [
        SELECT DeveloperName, NamespacePrefix
        FROM NamedCredential
      ]) {
        names.add(
          String.isBlank(credential.NamespacePrefix)
            ? credential.DeveloperName
            : credential.NamespacePrefix + '__' + credential.DeveloperName
        );
      }
      setNamedCredentialNames(names);
    }
    return namedCredentialNames.contains(name.toLowerCase());
  }

  // ---------------------------------------------------------------------------
  // Types
  // ---------------------------------------------------------------------------

  /**
   * Validated, typed view of an Integration_Configuration__mdt record. Optional numeric and
   * status code settings are null when blank, so callers can fall back to their own defaults.
   */
  public class IntegrationConfig {
    public String integrationName { get; private set; }
    public String label { get; private set; }
    public String namedCredential { get; private set; }
    /** 'callout:<Named Credential>' followed by the base path, e.g. 'callout:Stripe_API/v1'. */
    public String baseEndpoint { get; private set; }
    public Integer timeoutMs { get; private set; }
    public Integer maxRetries { get; private set; }
    public Integer retryDelayMs { get; private set; }
    public Set<Integer> retryableStatusCodes { get; private set; }
    public Integer maxCalloutsPerTransaction { get; private set; }
    public Integer defaultRetryAfterSeconds { get; private set; }
    public Map<String, String> defaultHeaders { get; private set; }
    /** Salesforce field API name => external field name. */
    public Map<String, String> fieldMappings { get; private set; }
    public Map<String, Object> settings { get; private set; }
    public Boolean loggingEnabled { get; private set; }
    public Boolean logPayloads { get; private set; }

    private List<String> errors = new List<String>();

    public IntegrationConfig(Integration_Configuration__mdt record) {
      integrationName = record.DeveloperName;
      label = record.MasterLabel;
      loggingEnabled = record.Logging_Enabled__c;
      logPayloads = record.Log_Payloads__c;

      namedCredential = record.Named_Credential__c?.trim()
        ?.removeStartIgnoreCase(CALLOUT_PREFIX);
      if (String.isBlank(namedCredential)) {
        errors.add('Named_Credential__c is required');
      } else if (!namedCredentialExists(namedCredential)) {
        errors.add('Named Credential ' + namedCredential + ' does not exist');
      }
      baseEndpoint = CALLOUT_PREFIX + namedCredential + parseBasePath(record.Base_Path__c);

      Integer timeoutSeconds = parseInteger(
        'Timeout_Seconds__c',
        record.Timeout_Seconds__c,
        1,
        MAX_TIMEOUT_SECONDS
      );
      timeoutMs = timeoutSeconds == null ? null : timeoutSeconds * 1000;
      maxRetries = parseInteger('Max_Retries__c', record.Max_Retries__c, 0, null);
      retryDelayMs = parseInteger('Retry_Delay_Ms__c', record.Retry_Delay_Ms__c, 0, null);
      maxCalloutsPerTransaction = parseInteger(
        'Max_Callouts_Per_Transaction__c',
        record.Max_Callouts_Per_Transaction__c,
        1,
        null
      );
      defaultRetryAfterSeconds = parseInteger(
        'Default_Retry_After_Seconds__c',
        record.Default_Retry_After_Seconds__c,
        0,
        null
      );
      retryableStatusCodes = parseStatusCodes(record.Retryable_Status_Codes__c);

      defaultHeaders = parseStringMap('Default_Headers__c', record.Default_Headers__c);
      for (String name : defaultHeaders.keySet()) {
        if (FORBIDDEN_HEADERS.contains(name.toLowerCase())) {
          errors.add(
            'Default_Headers__c must not contain ' +
              name +
              '; credentials belong in the Named Credential'
          );
        }
      }
      fieldMappings = parseStringMap('Field_Mappings__c', record.Field_Mappings__c);
      settings = parseJsonObject('Additional_Settings__c', record.Additional_Settings__c);

      if (!errors.isEmpty()) {
        throw new ConfigurationException(
          'Invalid configuration for integration ' +
            integrationName +
            ': ' +
            String.join(errors, '; ')
        );
      }
    }

    /** Value of a key in Additional_Settings__c, or null when it is not set. */
    public Object getSetting(String name) {
      return settings.get(name);
    }

    private String parseBasePath(String value) {
      String path = value?.trim();
      if (String.isBlank(path)) {
        return '';
      }
      if (path.contains('://')) {
        errors.add(
          'Base_Path__c must be a path such as /v1; the host belongs in the Named Credential'
        );
      }
      return '/' + path.removeStart('/').removeEnd('/');
    }

    private Integer parseInteger(
      String fieldName,
      Decimal value,
      Integer min,
      Integer max
    ) {
      if (value == null) {
        return null;
      }
      Integer result = value.intValue();
      if (result < min || (max != null && result > max)) {
        errors.add(
          fieldName +
            ' must be ' +
            (max == null ? 'at least ' + min : 'between ' + min + ' and ' + max)
        );
      }
      return result;
    }

    private Set<Integer> parseStatusCodes(String value) {
      if (String.isBlank(value)) {
        return null;
      }
      Set<Integer> codes = new Set<Integer>();
      for (String code : value.split(',')) {
        code = code.trim();
        if (code.isNumeric() && Integer.valueOf(code) >= 100 && Integer.valueOf(code) <= 599) {
          codes.add(Integer.valueOf(code));
        } else {
          errors.add('Retryable_Status_Codes__c contains an invalid status code: ' + code);
        }
      }
      return codes;
    }

    private Map<String, String> parseStringMap(String fieldName, String value) {
      Map<String, String> result = new Map<String, String>();
      Map<String, Object> parsed = parseJsonObject(fieldName, value);
      for (String key : parsed.keySet()) {
        Object entry = parsed.get(key);
        if (entry instanceof String) {
          result.put(key, (String) entry);
        } else {
          errors.add(fieldName + ' value for "' + key + '" must be a string');
        }
      }
      return result;
    }

    private Map<String, Object> parseJsonObject(String fieldName, String value) {
      if (String.isBlank(value)) {
        return new Map<String, Object>();
      }
      try {
        Object parsed = JSON.deserializeUntyped(value);
        if (parsed instanceof Map<String, Object>) {
          return (Map<String, Object>) parsed;
        }
      } catch (JSONException e) {
        // Reported below with the same message as a non-object value.
      }
      errors.add(fieldName + ' must be a JSON object');
      return new Map<String, Object>();
    }
  }

  public class ConfigurationException extends BaseIntegrationHandler.IntegrationException {
  }
}

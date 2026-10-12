/**
 * Base class for integrations configured through Integration_Configuration__mdt.
 *
 * Subclasses only implement getIntegrationName(), which must match the record's DeveloperName.
 * The endpoint comes from the record's Named Credential and the callout policy from its fields;
 * blank fields fall back to the BaseIntegrationHandler defaults. Configuration is loaded on first
 * use, so a missing, inactive or invalid record surfaces as a ConfigurationException from execute().
 */
public abstract inherited sharing class ConfiguredIntegrationHandler extends BaseIntegrationHandler {
  private IntegrationConfigLoader.IntegrationConfig config;

  protected IntegrationConfigLoader.IntegrationConfig getConfig() {
    if (config == null) {
      config = IntegrationConfigLoader.load(getIntegrationName());
    }
    return config;
  }

  protected virtual override String getBaseEndpoint() {
    return getConfig().baseEndpoint;
  }

  protected virtual override Integer getTimeoutMs() {
    return getConfig().timeoutMs ?? super.getTimeoutMs();
  }

  protected virtual override Integer getMaxRetries() {
    return getConfig().maxRetries ?? super.getMaxRetries();
  }

  protected virtual override Integer getMaxCalloutsPerTransaction() {
    return getConfig().maxCalloutsPerTransaction ??
      super.getMaxCalloutsPerTransaction();
  }

  protected virtual override Integer getDefaultRetryAfterSeconds() {
    return getConfig().defaultRetryAfterSeconds ??
      super.getDefaultRetryAfterSeconds();
  }

  protected virtual override Set<Integer> getRetryableStatusCodes() {
    return getConfig().retryableStatusCodes ?? super.getRetryableStatusCodes();
  }

  /** Framework defaults overlaid with the configured headers. */
  protected virtual override Map<String, String> getDefaultHeaders() {
    Map<String, String> headers = new Map<String, String>(
      super.getDefaultHeaders() ?? new Map<String, String>()
    );
    headers.putAll(getConfig().defaultHeaders);
    return headers;
  }
}

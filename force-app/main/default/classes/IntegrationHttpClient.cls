/**
 * Transport used by BaseIntegrationHandler to send HTTP requests. Exists so the transport
 * can be replaced, e.g. with an fflib_ApexMocks mock in unit tests.
 */
public interface IntegrationHttpClient {
  HttpResponse send(HttpRequest request);
}

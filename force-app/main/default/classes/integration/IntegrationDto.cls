/**
 * Base class for typed integration payloads: request bodies sent to and response bodies
 * received from external systems.
 *
 * Subclasses declare public fields that mirror the JSON contract and implement validate()
 * with the rules the data must satisfy. Validation runs in both directions:
 *  - serialize() validates before producing JSON, so invalid data never leaves Salesforce.
 *  - deserialize()/deserializeList() validate after parsing, so invalid data never enters it.
 * All violations are reported together in a DtoValidationException, with paths such as
 * 'lines[0].sku'. Malformed or mistyped JSON raises a DtoParseException.
 *
 * JSON names that are reserved in Apex (e.g. 'type', 'number') are mapped through
 * getJsonFieldNames(). Subclasses must keep a public no-argument constructor and must not
 * add instance fields to this base class, because every field is serialized.
 */
public abstract inherited sharing class IntegrationDto {
  /** Declares the rules this payload must satisfy; nested DTOs are validated via validator.nested(). */
  protected abstract void validate(Validator validator);

  /**
   * Maps Apex field names to JSON names, e.g. { 'type_x' => 'type' }. Mappings declared on the
   * root DTO are applied at every level of the payload, including nested DTOs.
   */
  protected virtual Map<String, String> getJsonFieldNames() {
    return new Map<String, String>();
  }

  /** When true, inbound payloads containing fields this DTO does not declare are rejected. */
  protected virtual Boolean rejectUnknownFields() {
    return false;
  }

  public List<String> getValidationErrors() {
    List<String> errors = new List<String>();
    validate(new Validator('', errors));
    return errors;
  }

  public Boolean isValid() {
    return getValidationErrors().isEmpty();
  }

  /** @throws DtoValidationException listing every rule violation. */
  public void assertValid() {
    throwIfInvalid(getDtoName(this), getValidationErrors());
  }

  /**
   * Validates the DTO and serializes it to JSON, omitting null fields.
   * @throws DtoValidationException when the DTO is invalid.
   */
  public String serialize() {
    assertValid();
    String payload = JSON.serialize(this, true);
    Map<String, String> jsonFieldNames = getJsonFieldNames();
    if (jsonFieldNames.isEmpty()) {
      return payload;
    }
    return JSON.serialize(
      renameKeys(JSON.deserializeUntyped(payload), jsonFieldNames)
    );
  }

  /**
   * Parses a JSON object into the given DTO type and validates it.
   * @throws DtoParseException when the JSON is malformed or does not match the type.
   * @throws DtoValidationException when the parsed DTO is invalid.
   */
  public static IntegrationDto deserialize(String payload, Type dtoType) {
    IntegrationDto prototype = newPrototype(dtoType);
    IntegrationDto dto = (IntegrationDto) parse(payload, dtoType, prototype);
    if (dto == null) {
      throw new DtoParseException('Expected a ' + dtoType.getName() + ' but got null');
    }
    dto.assertValid();
    return dto;
  }

  /**
   * Parses a JSON array into a list of the given DTO type and validates every element.
   * The result can be cast to the concrete list type, e.g. (List<OrderDto>).
   */
  public static List<IntegrationDto> deserializeList(String payload, Type dtoType) {
    IntegrationDto prototype = newPrototype(dtoType);
    Type listType = Type.forName('List<' + dtoType.getName() + '>');
    List<IntegrationDto> dtos = (List<IntegrationDto>) parse(
      payload,
      listType,
      prototype
    );
    if (dtos == null) {
      throw new DtoParseException('Expected a list of ' + dtoType.getName() + ' but got null');
    }

    List<String> errors = new List<String>();
    // JSON.deserialize already rejects null elements in a typed list.
    for (Integer i = 0; i < dtos.size(); i++) {
      dtos[i].validate(new Validator('[' + i + ']', errors));
    }
    throwIfInvalid('List<' + dtoType.getName() + '>', errors);
    return dtos;
  }

  private static IntegrationDto newPrototype(Type dtoType) {
    Object instance = dtoType?.newInstance();
    if (!(instance instanceof IntegrationDto)) {
      throw new DtoParseException(dtoType + ' does not extend IntegrationDto');
    }
    return (IntegrationDto) instance;
  }

  private static Object parse(
    String payload,
    Type targetType,
    IntegrationDto prototype
  ) {
    if (String.isBlank(payload)) {
      throw new DtoParseException(
        'Cannot parse an empty payload into ' + targetType.getName()
      );
    }
    try {
      Map<String, String> jsonFieldNames = prototype.getJsonFieldNames();
      if (!jsonFieldNames.isEmpty()) {
        payload = JSON.serialize(
          renameKeys(JSON.deserializeUntyped(payload), invert(jsonFieldNames))
        );
      }
      return prototype.rejectUnknownFields()
        ? JSON.deserializeStrict(payload, targetType)
        : JSON.deserialize(payload, targetType);
    } catch (JSONException e) {
      throw new DtoParseException(
        'Payload does not match ' + targetType.getName() + ': ' + e.getMessage(),
        e
      );
    } catch (TypeException e) {
      throw new DtoParseException(
        'Payload does not match ' + targetType.getName() + ': ' + e.getMessage(),
        e
      );
    }
  }

  private static Object renameKeys(Object node, Map<String, String> names) {
    if (node instanceof Map<String, Object>) {
      Map<String, Object> source = (Map<String, Object>) node;
      Map<String, Object> renamed = new Map<String, Object>();
      for (String key : source.keySet()) {
        renamed.put(
          names.containsKey(key) ? names.get(key) : key,
          renameKeys(source.get(key), names)
        );
      }
      return renamed;
    }
    if (node instanceof List<Object>) {
      List<Object> renamed = new List<Object>();
      for (Object item : (List<Object>) node) {
        renamed.add(renameKeys(item, names));
      }
      return renamed;
    }
    return node;
  }

  private static Map<String, String> invert(Map<String, String> names) {
    Map<String, String> inverted = new Map<String, String>();
    for (String key : names.keySet()) {
      inverted.put(names.get(key), key);
    }
    return inverted;
  }

  private static void throwIfInvalid(String dtoName, List<String> errors) {
    if (errors.isEmpty()) {
      return;
    }
    DtoValidationException e = new DtoValidationException(
      dtoName + ' is invalid: ' + String.join(errors, '; ')
    );
    e.errors = errors;
    throw e;
  }

  private static String getDtoName(Object dto) {
    return String.valueOf(dto).substringBefore(':');
  }

  /** Collects rule violations; every method is chainable and null-safe unless noted. */
  public class Validator {
    private String path;
    private List<String> errors;

    public Validator(String path, List<String> errors) {
      this.path = path;
      this.errors = errors;
    }

    /** Fails when the value is null or a blank String. */
    public Validator required(String field, Object value) {
      if (value == null || (value instanceof String && String.isBlank((String) value))) {
        addError(field, 'is required');
      }
      return this;
    }

    /** Fails when the list is null or empty. */
    public Validator notEmpty(String field, List<Object> values) {
      if (values == null || values.isEmpty()) {
        addError(field, 'must not be empty');
      }
      return this;
    }

    public Validator maxLength(String field, String value, Integer maxLength) {
      if (value != null && value.length() > maxLength) {
        addError(field, 'must be at most ' + maxLength + ' characters');
      }
      return this;
    }

    /** Fails when the value does not fully match the regular expression. */
    public Validator pattern(String field, String value, String regex) {
      if (value != null && !Pattern.matches(regex, value)) {
        addError(field, 'has an invalid format');
      }
      return this;
    }

    public Validator allowedValues(
      String field,
      String value,
      Set<String> allowed
    ) {
      if (value != null && !allowed.contains(value)) {
        addError(field, 'must be one of ' + allowed);
      }
      return this;
    }

    /** Inclusive range; pass null for an open bound. */
    public Validator range(String field, Decimal value, Decimal min, Decimal max) {
      if (value != null && min != null && value < min) {
        addError(field, 'must be at least ' + min);
      }
      if (value != null && max != null && value > max) {
        addError(field, 'must be at most ' + max);
      }
      return this;
    }

    /** Validates a nested DTO, prefixing its errors with the field name. */
    public Validator nested(String field, IntegrationDto child) {
      if (child != null) {
        child.validate(new Validator(qualify(field), errors));
      }
      return this;
    }

    /** Validates each DTO in a list, prefixing errors with 'field[index]'. */
    public Validator nested(String field, List<IntegrationDto> children) {
      if (children == null) {
        return this;
      }
      for (Integer i = 0; i < children.size(); i++) {
        if (children[i] == null) {
          addError(field + '[' + i + ']', 'is required');
        } else {
          children[i].validate(new Validator(qualify(field) + '[' + i + ']', errors));
        }
      }
      return this;
    }

    /** Records a custom rule violation. */
    public Validator addError(String field, String message) {
      errors.add(qualify(field) + ' ' + message);
      return this;
    }

    private String qualify(String field) {
      return String.isBlank(path) ? field : path + '.' + field;
    }
  }

  public class DtoValidationException extends BaseIntegrationHandler.IntegrationException {
    public List<String> errors { get; set; }
  }

  public class DtoParseException extends BaseIntegrationHandler.IntegrationException {
  }
}

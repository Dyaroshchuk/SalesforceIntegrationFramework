@IsTest
private class IntegrationDtoTest {
  private static final String VALID_ORDER_JSON =
    '{"orderNumber":"SO-000123","type":"Online","status":"Draft","total":125.50,' +
    '"orderDate":"2026-10-10","shipTo":{"city":"Dublin","countryCode":"IE"},' +
    '"lines":[{"sku":"SKU-1","quantity":2}]}';

  @IsTest
  static void serializeMapsFieldNamesAndOmitsNulls() {
    OrderDto order = validOrder();
    order.status = null;

    Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(
      order.serialize()
    );

    Assert.areEqual('Online', payload.get('type'));
    Assert.isFalse(payload.containsKey('type_x'));
    Assert.isFalse(payload.containsKey('status'));
    Assert.areEqual('2026-10-10', payload.get('orderDate'));
    Map<String, Object> shipTo = (Map<String, Object>) payload.get('shipTo');
    Assert.areEqual('IE', shipTo.get('countryCode'));
    List<Object> lines = (List<Object>) payload.get('lines');
    Assert.areEqual('SKU-1', ((Map<String, Object>) lines[0]).get('sku'));
  }

  @IsTest
  static void serializeRejectsInvalidDtoWithAllErrors() {
    OrderDto order = validOrder();
    order.orderNumber = null;
    order.status = 'Bogus';
    order.total = -1;
    order.shipTo.countryCode = 'usa';
    order.lines[0].sku = ' ';
    order.lines[0].quantity = 0;

    try {
      order.serialize();
      Assert.fail('Expected DtoValidationException');
    } catch (IntegrationDto.DtoValidationException e) {
      Assert.areEqual(6, e.errors.size(), String.join(e.errors, '\n'));
      Assert.isTrue(e.errors.contains('orderNumber is required'));
      Assert.isTrue(e.errors[1].startsWith('status must be one of'));
      Assert.isTrue(e.errors.contains('total must be at least 0'));
      Assert.isTrue(e.errors.contains('shipTo.countryCode has an invalid format'));
      Assert.isTrue(e.errors.contains('lines[0].sku is required'));
      Assert.isTrue(e.errors.contains('lines[0].quantity must be at least 1'));
      Assert.isTrue(e.getMessage().startsWith('OrderDto is invalid: '));
    }
  }

  @IsTest
  static void validatorChecksLengthPatternAndCustomRules() {
    OrderDto order = validOrder();
    order.orderNumber = '123';
    order.shipTo.city = 'x'.repeat(41);
    order.lines.add(null);
    order.lines[0].quantity = 1000;

    List<String> errors = order.getValidationErrors();

    Assert.isFalse(order.isValid());
    Assert.areEqual(
      new List<String>{
        'orderNumber has an invalid format',
        'shipTo.city must be at most 40 characters',
        'lines[0].quantity must be at most 999',
        'lines[1] is required'
      },
      errors
    );
  }

  @IsTest
  static void deserializeMapsFieldNamesAndBuildsTypedDto() {
    OrderDto order = (OrderDto) IntegrationDto.deserialize(
      VALID_ORDER_JSON,
      OrderDto.class
    );

    Assert.areEqual('SO-000123', order.orderNumber);
    Assert.areEqual('Online', order.type_x);
    Assert.areEqual(125.50, order.total);
    Assert.areEqual(Date.newInstance(2026, 10, 10), order.orderDate);
    Assert.areEqual('Dublin', order.shipTo.city);
    Assert.areEqual(2, order.lines[0].quantity);
  }

  @IsTest
  static void serializeAndDeserializeRoundTrip() {
    String payload = validOrder().serialize();

    OrderDto order = (OrderDto) IntegrationDto.deserialize(payload, OrderDto.class);

    Assert.areEqual(payload, order.serialize());
  }

  @IsTest
  static void deserializeRejectsInvalidPayload() {
    try {
      IntegrationDto.deserialize(
        '{"orderNumber":"SO-000123","lines":[{"quantity":1}]}',
        OrderDto.class
      );
      Assert.fail('Expected DtoValidationException');
    } catch (IntegrationDto.DtoValidationException e) {
      Assert.areEqual(new List<String>{ 'lines[0].sku is required' }, e.errors);
    }
  }

  @IsTest
  static void deserializeRejectsMistypedPayload() {
    assertParseFails('{"orderNumber":"SO-000123","total":"lots"}', OrderDto.class);
    assertParseFails('{"orderNumber":', OrderDto.class);
    assertParseFails('[]', OrderDto.class);
    assertParseFails('', OrderDto.class);
    assertParseFails('null', OrderDto.class);
  }

  @IsTest
  static void deserializeRejectsTypesThatAreNotDtos() {
    assertParseFails('{}', NotADto.class);
    assertParseFails('{}', null);
  }

  @IsTest
  static void unknownFieldsAreIgnoredUnlessDtoIsStrict() {
    String payload = '{"code":"X1","unexpected":true}';

    Assert.areEqual(
      'X1',
      ((LenientCodeDto) IntegrationDto.deserialize(payload, LenientCodeDto.class)).code
    );
    assertParseFails(payload, StrictCodeDto.class);
  }

  @IsTest
  static void deserializeListValidatesEveryElement() {
    List<OrderDto> orders = (List<OrderDto>) IntegrationDto.deserializeList(
      '[' + VALID_ORDER_JSON + ',' + VALID_ORDER_JSON + ']',
      OrderDto.class
    );
    Assert.areEqual(2, orders.size());
    Assert.areEqual('Online', orders[1].type_x);

    try {
      IntegrationDto.deserializeList(
        '[' + VALID_ORDER_JSON + ',{"lines":[{"sku":"A","quantity":1}]}]',
        OrderDto.class
      );
      Assert.fail('Expected DtoValidationException');
    } catch (IntegrationDto.DtoValidationException e) {
      Assert.areEqual(new List<String>{ '[1].orderNumber is required' }, e.errors);
    }

    try {
      IntegrationDto.deserializeList('[' + VALID_ORDER_JSON + ',null]', OrderDto.class);
      Assert.fail('Expected DtoParseException');
    } catch (IntegrationDto.DtoParseException e) {
      Assert.isNotNull(e.getMessage());
    }
  }

  @IsTest
  static void handlerRequestAndResponseUseDtos() {
    OrderDto order = validOrder();

    BaseIntegrationHandler.IntegrationRequest request = new BaseIntegrationHandler.IntegrationRequest(
        'POST',
        'orders'
      )
      .setBody(order);
    Assert.areEqual(order.serialize(), request.body);

    HttpResponse httpResponse = new HttpResponse();
    httpResponse.setStatusCode(200);
    httpResponse.setBody('[' + VALID_ORDER_JSON + ']');
    BaseIntegrationHandler.IntegrationResponse response = new BaseIntegrationHandler.IntegrationResponse(
      httpResponse,
      1,
      0
    );
    List<OrderDto> orders = (List<OrderDto>) response.readBodyList(OrderDto.class);
    Assert.areEqual('SO-000123', orders[0].orderNumber);

    httpResponse.setBody(VALID_ORDER_JSON);
    response = new BaseIntegrationHandler.IntegrationResponse(httpResponse, 1, 0);
    Assert.areEqual('Dublin', ((OrderDto) response.readBody(OrderDto.class)).shipTo.city);
  }

  private static void assertParseFails(String payload, Type dtoType) {
    try {
      IntegrationDto.deserialize(payload, dtoType);
      Assert.fail('Expected DtoParseException for ' + payload);
    } catch (IntegrationDto.DtoParseException e) {
      Assert.isNotNull(e.getMessage());
    }
  }

  private static OrderDto validOrder() {
    OrderDto order = new OrderDto();
    order.orderNumber = 'SO-000123';
    order.type_x = 'Online';
    order.status = 'Draft';
    order.total = 125.50;
    order.orderDate = Date.newInstance(2026, 10, 10);
    order.shipTo = new AddressDto();
    order.shipTo.city = 'Dublin';
    order.shipTo.countryCode = 'IE';
    OrderLineDto line = new OrderLineDto();
    line.sku = 'SKU-1';
    line.quantity = 2;
    order.lines = new List<OrderLineDto>{ line };
    return order;
  }

  public class OrderDto extends IntegrationDto {
    public String orderNumber;
    public String type_x;
    public String status;
    public Decimal total;
    public Date orderDate;
    public AddressDto shipTo;
    public List<OrderLineDto> lines;

    protected override Map<String, String> getJsonFieldNames() {
      return new Map<String, String>{ 'type_x' => 'type' };
    }

    protected override void validate(IntegrationDto.Validator validator) {
      validator
        .required('orderNumber', orderNumber)
        .pattern('orderNumber', orderNumber, 'SO-\\d{6}')
        .allowedValues('status', status, new Set<String>{ 'Draft', 'Submitted' })
        .range('total', total, 0, null)
        .notEmpty('lines', lines)
        .nested('shipTo', shipTo)
        .nested('lines', lines);
    }
  }

  public class AddressDto extends IntegrationDto {
    public String city;
    public String countryCode;

    protected override void validate(IntegrationDto.Validator validator) {
      validator
        .required('city', city)
        .maxLength('city', city, 40)
        .pattern('countryCode', countryCode, '[A-Z]{2}');
    }
  }

  public class OrderLineDto extends IntegrationDto {
    public String sku;
    public Integer quantity;

    protected override void validate(IntegrationDto.Validator validator) {
      validator
        .required('sku', sku)
        .required('quantity', quantity)
        .range('quantity', quantity, 1, 999);
    }
  }

  public virtual class LenientCodeDto extends IntegrationDto {
    public String code;

    protected override void validate(IntegrationDto.Validator validator) {
      validator.required('code', code);
    }
  }

  public class StrictCodeDto extends LenientCodeDto {
    protected override Boolean rejectUnknownFields() {
      return true;
    }
  }

  public class NotADto {
  }
}

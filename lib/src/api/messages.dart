part of kafka;

/// Kafka Message Attributes. Only [KafkaCompression] is supported by the
/// server at the moment.
class MessageAttributes {
  /// Compression codec.
  final KafkaCompression compression;

  /// Creates new instance of MessageAttributes.
  MessageAttributes([this.compression = KafkaCompression.none]);

  /// Creates MessageAttributes from the raw byte.
  MessageAttributes.readFrom(int byte) : compression = getCompression(byte);

  static KafkaCompression getCompression(int byte) {
    var c = byte & 3;
    switch (c) {
      case 0:
        return KafkaCompression.none;
      case 1:
        return KafkaCompression.gzip;
      case 2:
        return KafkaCompression.snappy;
      default:
        throw new KafkaClientError('Unsupported compression codec: ${c}.');
    }
  }

  /// Converts this attributes into byte.
  int toInt() {
    return _compressionToInt();
  }

  int _compressionToInt() {
    switch (this.compression) {
      case KafkaCompression.none:
        return 0;
      case KafkaCompression.gzip:
        return 1;
      case KafkaCompression.snappy:
        return 2;
    }
  }
}

/// Kafka Message as defined in the protocol.
class Message {
  /// This is a version id used to allow backwards compatible evolution
  /// of the message binary format. The current value is 0.
  final int magicByte;

  /// Metadata attributes about this message.
  final MessageAttributes attributes;

  /// Actual message contents.
  final List<int> value;

  /// Optional message key that was used for partition assignment. The key can be `null`.
  final List<int> key;

  /// Default internal constructor.
  Message._internal(this.attributes, this.key, this.value,
      [this.magicByte = 0]);

  /// Creates new [Message].
  factory Message(List<int> value,
      [MessageAttributes attributes, List<int> key]) {
    attributes ??= new MessageAttributes();
    return new Message._internal(attributes, key, value);
  }

  /// Creates new instance of [Message] from the received data.
  factory Message.readFrom(KafkaBytesReader reader) {
    var magicByte = reader.readInt8();
    var attributes = new MessageAttributes.readFrom(reader.readInt8());
    var key = reader.readBytes();
    var value = reader.readBytes();

    return new Message._internal(attributes, key, value, magicByte);
  }

  /// Converts Message to a list of bytes.
  List<int> toBytes() {
    var builder = new KafkaBytesBuilder();
    builder.addInt8(magicByte);
    builder.addInt8(attributes.toInt());
    builder.addBytes(key);
    builder.addBytes(value);

    var data = builder.takeBytes();
    int crc = Crc32.signed(data);
    builder.addInt32(crc);
    builder.addRaw(data);

    return builder.toBytes();
  }
}

/// Kafka MessageSet type as defined in the protocol specification.
class MessageSet {
  /// Collection of messages. Keys in the map are message offsets.
  final Map<int, Message> _messages = new Map();

  /// Map of message offsets to messages.
  Map<int, Message> get messages => new UnmodifiableMapView(_messages);

  /// Number of messages in this message set.
  int get length => _messages.length;

  /// Creates new empty message set.
  MessageSet();

  /// Creates new MessageSet from provided data.
  MessageSet.readFrom(KafkaBytesReader reader) {
    int messageSize = 0;
    while (reader.isNotEOF) {
      try {
        int offset = reader.readInt64();
        messageSize = reader.readInt32();
        var crc = reader.readInt32();

        var data = reader.readRaw(messageSize - 4);
        var actualCrc = Crc32.signed(data);
        if (actualCrc != crc) {
          _logger.warning(
              'Message CRC sum mismatch. Expected crc: ${crc}, actual: ${actualCrc}');
          throw new MessageCrcMismatchError(
              'Expected crc: ${crc}, actual: ${actualCrc}');
        }
        var messageReader = new KafkaBytesReader.fromBytes(data);
        var message = new Message.readFrom(messageReader);
        this._messages[offset] = message;
      } on RangeError {
        // According to spec server is allowed to return partial
        // messages, so we just ignore it here and exit the loop.
        var remaining = reader.length - reader.offset;
        _logger?.info(
            'Encountered partial message. Expected message size: ${messageSize}, bytes left in buffer: ${remaining}, total buffer size ${reader.length}');
        break;
      }
    }
  }

  /// Adds [Message] to this message set.
  ///
  /// Offset for this new message will be autogenerated.
  void addMessage(Message message) {
    var offset = _messages.length;
    _messages[offset] = message;
  }

  /// Converts this MessageSet into sequence of bytes conforming to Kafka
  /// protocol spec.
  List<int> toBytes() {
    var builder = new KafkaBytesBuilder();
    _messages.forEach((offset, message) {
      var messageData = message.toBytes();
      builder.addInt64(offset);
      builder.addInt32(messageData.length);
      builder.addRaw(messageData);
    });

    return builder.toBytes();
  }
}

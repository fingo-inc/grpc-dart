// Copyright (c) 2018, the gRPC project authors. Please see the AUTHORS file
// for details. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart';
import 'package:meta/meta.dart';

import '../../client/call.dart';
import '../../shared/message.dart';
import '../../shared/status.dart';
import '../connection.dart';
import 'transport.dart';
import 'web_streams.dart';

const _contentTypeKey = 'Content-Type';

const _validContentTypePrefix = [
  'application/grpc',
  'application/json+protobuf',
  'application/x-protobuf'
];

class XhrTransportStream implements GrpcTransportStream {
  final Client _client;
  final Request _request;
  final ErrorHandler _onError;
  final Function(XhrTransportStream stream) _onDone;
  final StreamController<ByteBuffer> _incomingProcessor = StreamController();
  final StreamController<GrpcMessage> _incomingMessages = StreamController();
  final StreamController<List<int>> _outgoingMessages = StreamController();

  @override
  Stream<GrpcMessage> get incomingMessages => _incomingMessages.stream;

  @override
  StreamSink<List<int>> get outgoingMessages => _outgoingMessages.sink;

  XhrTransportStream(this._client, this._request,
      {required ErrorHandler onError, required onDone})
      : _onError = onError,
        _onDone = onDone {
    final asyncOnError = (e, st) {
      if (_incomingMessages.isClosed) {
        return;
      }
      _onError(GrpcError.unavailable('XhrConnection connection-error'),
          StackTrace.current);
      terminate();
    };
    _outgoingMessages.stream.map(frame).listen((data) {
      _request.bodyBytes = data;
      _client.send(_request).then((response) {
        if (_incomingMessages.isClosed) {
          return;
        }
        if (!_onHeadersReceived(response)) {
          return;
        }
        response.stream.listen((data) {
          _incomingProcessor.add(Uint8List.fromList(data).buffer);
        }, onDone: _close);
      }).catchError(asyncOnError);
    }, cancelOnError: true, onError: asyncOnError);

    _incomingProcessor.stream
        .transform(GrpcWebDecoder())
        .transform(grpcDecompressor())
        .listen(_incomingMessages.add,
            onError: _onError, onDone: _incomingMessages.close);
  }

  bool _checkContentType(String contentType) {
    return _validContentTypePrefix.any(contentType.startsWith);
  }

  bool _onHeadersReceived(StreamedResponse response) {
    final contentType = response.headers['content-type'];
    if (response.statusCode != 200) {
      _onError(
          GrpcError.unavailable('XhrConnection status ${response.statusCode}'),
          StackTrace.current);
      return false;
    }
    if (contentType == null) {
      _onError(GrpcError.unavailable('XhrConnection missing Content-Type'),
          StackTrace.current);
      return false;
    }
    if (!_checkContentType(contentType)) {
      _onError(
          GrpcError.unavailable('XhrConnection bad Content-Type $contentType'),
          StackTrace.current);
      return false;
    }
    final encoding = response.headers['grpc-encoding'];
    if (encoding != null && encoding != 'gzip') {
      _onError(
          GrpcError.unavailable(
              'XhrConnection unsupported grpc-encoding $encoding'),
          StackTrace.current);
      return false;
    }

    // Force a metadata message with headers.
    final headers = GrpcMetadata(response.headers);
    _incomingMessages.add(headers);
    return true;
  }

  void _close() {
    _incomingProcessor.close();
    _outgoingMessages.close();
    _onDone(this);
  }

  @override
  Future<void> terminate() async {
    _close();
  }
}

class XhrClientConnection extends ClientConnection {
  final Uri uri;
  final _client = Client();

  final _requests = <XhrTransportStream>{};

  XhrClientConnection(this.uri);

  @override
  String get authority => uri.authority;
  @override
  String get scheme => uri.scheme;

  void _initializeRequest(Request request, Map<String, String> metadata) {
    for (final header in metadata.keys) {
      request.headers[header] = metadata[header]!;
    }
  }

  @visibleForTesting
  Request createHttpRequest(String path) => Request('POST', uri.resolve(path));

  @override
  GrpcTransportStream makeRequest(String path, Duration? timeout,
      Map<String, String> metadata, ErrorHandler onError,
      {required CallOptions callOptions}) {
    if (_getContentTypeHeader(metadata) == null) {
      metadata['Content-Type'] = 'application/grpc-web+proto';
      metadata['X-User-Agent'] = 'grpc-web-dart/0.1';
      metadata['X-Grpc-Web'] = '1';
    }
    final request = createHttpRequest(path);
    if (callOptions is WebCallOptions && callOptions.withCredentials == true) {
      // request.withCredentials = true;
    }
    // Must set headers after calling open().
    _initializeRequest(request, metadata);

    final transportStream = XhrTransportStream(_client, request,
        onError: onError, onDone: _removeStream);
    _requests.add(transportStream);
    return transportStream;
  }

  void _removeStream(XhrTransportStream stream) {
    _requests.remove(stream);
  }

  @override
  Future<void> terminate() async {
    for (var request in List.of(_requests)) {
      request.terminate();
    }
  }

  @override
  void dispatchCall(ClientCall call) {
    call.onConnectionReady(this);
  }

  @override
  Future<void> shutdown() async {}
}

MapEntry<String, String>? _getContentTypeHeader(Map<String, String> metadata) {
  for (var entry in metadata.entries) {
    if (entry.key.toLowerCase() == _contentTypeKey.toLowerCase()) {
      return entry;
    }
  }
  return null;
}

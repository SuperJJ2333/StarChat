/*
 *   Famedly Matrix SDK
 *   Copyright (C) 2021 Famedly GmbH
 *
 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU Affero General Public License as
 *   published by the Free Software Foundation, either version 3 of the
 *   License, or (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *   GNU Affero General Public License for more details.
 *
 *   You should have received a copy of the GNU Affero General Public License
 *   along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:async';

import 'package:http/http.dart' as http;

http.StreamedResponse replaceStream(
        http.StreamedResponse base, Stream<List<int>> stream) =>
    http.StreamedResponse(
      http.ByteStream(stream),
      base.statusCode,
      contentLength: base.contentLength,
      request: base.request,
      headers: base.headers,
      isRedirect: base.isRedirect,
      persistentConnection: base.persistentConnection,
      reasonPhrase: base.reasonPhrase,
    );

/// Http Client that enforces a timeout on requests.
/// Timeout calculation is done in a subclass.
abstract class TimeoutHttpClient extends http.BaseClient {
  TimeoutHttpClient(this.inner);

  http.Client inner;

  Duration get timeout;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // ChatFlow patch (2026-09-19, weak-network send recovery): bound the
    // request lifecycle itself. Only the response body stream was
    // timeout-protected before, so a black-holed connection (TCP established,
    // gateway silently dropping packets) could hang `inner.send()` forever,
    // which permanently blocked the head of `Room._sendingQueue` and paralyzed
    // every later send in that room until the process was killed.
    final response = await inner.send(request).timeout(timeout);
    return replaceStream(response, response.stream.timeout(timeout));
  }
}

class FixedTimeoutHttpClient extends TimeoutHttpClient {
  FixedTimeoutHttpClient(super.inner, this.timeout);
  @override
  Duration timeout;
}

import 'dart:async';
import 'dart:convert';

import 'package:gotrue/gotrue.dart';
import 'package:gotrue/src/constants.dart';
import 'package:gotrue/src/subscription.dart';
import 'package:gotrue/src/uuid.dart';

class GoTrueClient {
  /// Namespace for the GoTrue API methods.
  /// These can be used for example to get a user from a JWT in a server environment or reset a user's password.
  late GoTrueApi api;

  /// The currently logged in user or null.
  User? currentUser;

  /// The session object for the currently logged in user or null.
  Session? currentSession;

  late bool autoRefreshToken;
  Map<String, Subscription> stateChangeEmitters = {};

  Timer? _refreshTokenTimer;

  GoTrueClient({
    String? url,
    Map<String, String>? headers,
    bool? autoRefreshToken,
    CookieOptions? cookieOptions,
  }) {
    this.autoRefreshToken = autoRefreshToken ?? true;

    final _url = url ?? Constants.defaultGotrueUrl;
    final _header = {
      ...Constants.defaultHeaders,
      if (headers != null) ...headers,
    };
    api = GoTrueApi(_url, headers: _header, cookieOptions: cookieOptions);
  }

  /// Returns the user data, if there is a logged in user.
  User? user() {
    return currentUser;
  }

  /// Returns the session data, if there is an active session.
  Session? session() {
    return currentSession;
  }

  /// Creates a new user.
  Future<GotrueSessionResponse> signUp(
    String email,
    String password, {
    AuthOptions? options,
  }) async {
    _removeSession();

    final response =
        await api.signUpWithEmail(email, password, options: options);
    if (response.error != null) return response;

    // ignore: deprecated_member_use_from_same_package
    if (response.data?.user?.confirmedAt != null ||
        response.data?.user?.emailConfirmedAt != null) {
      _saveSession(response.data!);
      _notifyAllSubscribers(AuthChangeEvent.signedIn);
    }

    return response;
  }

  /// Signs up a new user using their phone number and a password.
  ///
  /// `phone` is the user's phone number WITH international prefix
  ///
  /// `password` is the password of the user
  Future<GotrueSessionResponse> signUpWithPhone(
    String phone,
    String password, {
    AuthOptions? options,
  }) async {
    _removeSession();

    final response = await api.signUpWithPhone(phone, password);
    if (response.error != null) return response;

    if (response.data?.user?.phoneConfirmedAt != null) {
      _saveSession(response.data!);
      _notifyAllSubscribers(AuthChangeEvent.signedIn);
    }

    return response;
  }

  /// Log in an existing user, or login via a third-party provider.
  Future<GotrueSessionResponse> signIn({
    String? email,
    String? phone,
    String? password,
    Provider? provider,
    AuthOptions? options,
  }) async {
    _removeSession();

    if (email != null) {
      if (password == null) {
        final response = await api.sendMagicLinkEmail(email, options: options);
        return GotrueSessionResponse(error: response.error);
      } else {
        return _handleEmailSignIn(email, password, options: options);
      }
    } else if (phone != null) {
      if (password == null) {
        final response = await api.sendMobileOTP(phone);
        return GotrueSessionResponse(error: response.error);
      } else {
        return _handlePhoneSignIn(phone, password);
      }
    } else if (provider != null) {
      return _handleProviderSignIn(provider, options);
    } else {
      final error = GotrueError(
        "You must provide either an email or a third-party provider.",
      );
      return GotrueSessionResponse(error: error);
    }
  }

  /// Log in a user given a User supplied OTP received via mobile.
  ///
  /// `phone` is the user's phone number WITH international prefix
  ///
  /// `token` is the token that user was sent to their mobile phone
  Future<GotrueSessionResponse> verifyOTP(
    String phone,
    String token, {
    AuthOptions? options,
  }) async {
    _removeSession();

    final response = await api.verifyMobileOTP(phone, token, options: options);

    if (response.error != null) return response;

    if (response.data?.accessToken != null) {
      _saveSession(response.data!);
      _notifyAllSubscribers(AuthChangeEvent.signedIn);
    }

    return response;
  }

  /// Force refreshes the session including the user data in case it was updated in a different session.
  Future<GotrueSessionResponse> refreshSession() async {
    if (currentSession?.accessToken == null) {
      final error = GotrueError('Not logged in.');
      return GotrueSessionResponse(error: error);
    }

    final response = await _callRefreshToken();
    return response;
  }

  /// Sets the session data from refresh_token and returns current Session and Error
  Future<GotrueSessionResponse> setSession(String refreshToken) async {
    if (refreshToken.isEmpty) {
      final error = GotrueError('No current session.');
      return GotrueSessionResponse(error: error);
    }
    return _callRefreshToken(refreshToken: refreshToken);
  }

  /// Overrides the JWT on the current client. The JWT will then be sent in all subsequent network requests.
  Session setAuth(String accessToken) =>
      currentSession = currentSession?.copyWith(accessToken: accessToken) ??
          Session(accessToken: accessToken, tokenType: 'bearer');

  /// Gets the session data from a oauth2 callback URL
  Future<GotrueSessionResponse> getSessionFromUrl(
    Uri originUrl, {
    bool storeSession = true,
  }) async {
    var url = originUrl;
    if (originUrl.hasQuery) {
      final decoded = originUrl.toString().replaceAll('#', '&');
      url = Uri.parse(decoded);
    } else {
      final decoded = originUrl.toString().replaceAll('#', '?');
      url = Uri.parse(decoded);
    }

    final errorDescription = url.queryParameters['error_description'];
    if (errorDescription != null) {
      return GotrueSessionResponse(error: GotrueError(errorDescription));
    }

    final accessToken = url.queryParameters['access_token'];
    final expiresIn = url.queryParameters['expires_in'];
    final refreshToken = url.queryParameters['refresh_token'];
    final tokenType = url.queryParameters['token_type'];
    final providerToken = url.queryParameters['provider_token'];

    if (accessToken == null) {
      return GotrueSessionResponse(
        error: GotrueError('No access_token detected.'),
      );
    }
    if (expiresIn == null) {
      return GotrueSessionResponse(
        error: GotrueError('No expires_in detected.'),
      );
    }
    if (refreshToken == null) {
      return GotrueSessionResponse(
        error: GotrueError('No refresh_token detected.'),
      );
    }
    if (tokenType == null) {
      return GotrueSessionResponse(
        error: GotrueError('No token_type detected.'),
      );
    }

    final response = await api.getUser(accessToken);
    if (response.error != null) {
      return GotrueSessionResponse(error: response.error);
    }

    final session = Session(
      accessToken: accessToken,
      expiresIn: int.parse(expiresIn),
      refreshToken: refreshToken,
      tokenType: tokenType,
      providerToken: providerToken,
      user: response.user,
    );

    if (storeSession == true) {
      _saveSession(session);
      _notifyAllSubscribers(AuthChangeEvent.signedIn);
      final type = url.queryParameters['type'];
      if (type == 'recovery') {
        _notifyAllSubscribers(AuthChangeEvent.passwordRecovery);
      }
    }

    return GotrueSessionResponse(data: session);
  }

  /// Updates user data, if there is a logged in user.
  Future<GotrueUserResponse> update(UserAttributes attributes) async {
    if (currentSession?.accessToken == null) {
      final error = GotrueError('Not logged in.');
      return GotrueUserResponse(error: error);
    }

    final response =
        await api.updateUser(currentSession!.accessToken, attributes);
    if (response.error != null) return response;

    currentUser = response.user;
    currentSession = currentSession?.copyWith(user: response.user);
    _notifyAllSubscribers(AuthChangeEvent.userUpdated);

    return response;
  }

  /// Signs out the current user, if there is a logged in user.
  Future<GotrueResponse> signOut() async {
    final accessToken = currentSession?.accessToken;
    _removeSession();
    _notifyAllSubscribers(AuthChangeEvent.signedOut);
    if (accessToken != null) {
      final response = await api.signOut(accessToken);
      if (response.error != null) return response;
    }
    return GotrueResponse();
  }

  // Receive a notification every time an auth event happens.
  GotrueSubscription onAuthStateChange(Callback callback) {
    final id = uuid.generateV4();
    final GoTrueClient self = this;
    final subscription = Subscription(
      id: id,
      callback: callback,
      unsubscribe: () {
        self.stateChangeEmitters.remove(id);
      },
    );
    stateChangeEmitters[id] = subscription;
    return GotrueSubscription(data: subscription);
  }

  /// Recover session from persisted session json string.
  /// Persisted session json has the format { currentSession, expiresAt }
  ///
  /// currentSession: session json object, expiresAt: timestamp in seconds
  Future<GotrueSessionResponse> recoverSession(String jsonStr) async {
    try {
      final persistedData = json.decode(jsonStr) as Map<String, dynamic>;
      final currentSession =
          persistedData['currentSession'] as Map<String, dynamic>?;
      final expiresAt = persistedData['expiresAt'] as int?;
      if (currentSession == null) {
        return GotrueSessionResponse(
          error: GotrueError('Missing currentSession.'),
        );
      }
      if (expiresAt == null) {
        return GotrueSessionResponse(error: GotrueError('Missing expiresAt.'));
      }

      final session = Session.fromJson(currentSession);
      if (session.user == null) {
        return GotrueSessionResponse(
          error: GotrueError('Current session is missing data.'),
        );
      }

      final timeNow = (DateTime.now().millisecondsSinceEpoch / 1000).round();
      if (expiresAt < timeNow) {
        if (autoRefreshToken && session.refreshToken != null) {
          final response =
              await _callRefreshToken(refreshToken: session.refreshToken);
          return response;
        } else {
          return GotrueSessionResponse(error: GotrueError('Session expired.'));
        }
      } else {
        _saveSession(session);
        _notifyAllSubscribers(AuthChangeEvent.signedIn);
        return GotrueSessionResponse(data: session);
      }
    } catch (e) {
      return GotrueSessionResponse(error: GotrueError(e.toString()));
    }
  }

  Future<GotrueSessionResponse> _handleEmailSignIn(
    String email,
    String password, {
    AuthOptions? options,
  }) async {
    final response =
        await api.signInWithEmail(email, password, options: options);
    if (response.error != null) return response;

    // ignore: deprecated_member_use_from_same_package
    if (response.data?.user?.confirmedAt != null ||
        response.data?.user?.emailConfirmedAt != null) {
      _saveSession(response.data!);
      _notifyAllSubscribers(AuthChangeEvent.signedIn);
    }

    return response;
  }

  /// return provider url only
  GotrueSessionResponse _handleProviderSignIn(
    Provider provider,
    AuthOptions? options,
  ) {
    final url = api.getUrlForProvider(provider, options);
    return GotrueSessionResponse(provider: provider.name(), url: url);
  }

  Future<GotrueSessionResponse> _handlePhoneSignIn(
    String phone, [
    String? password,
  ]) async {
    final response = await api.signInWithPhone(phone, password);

    if (response.error != null) return response;

    if (response.data?.user?.phoneConfirmedAt != null) {
      _saveSession(response.data!);
      _notifyAllSubscribers(AuthChangeEvent.signedIn);
    }

    return response;
  }

  void _saveSession(Session session) {
    currentSession = session;
    currentUser = session.user;
    final expiresAt = session.expiresAt;

    if (autoRefreshToken && expiresAt != null) {
      if (_refreshTokenTimer != null) {
        _refreshTokenTimer!.cancel();
      }

      final timeNow = (DateTime.now().millisecondsSinceEpoch / 1000).round();
      final expiresIn = expiresAt - timeNow;
      final refreshDurationBeforeExpires = expiresIn > 60 ? 60 : 1;
      final nextDuration = expiresIn - refreshDurationBeforeExpires;
      if (nextDuration > 0) {
        final timerDuration = Duration(seconds: nextDuration);
        _refreshTokenTimer = Timer(timerDuration, () {
          _callRefreshToken();
        });
      } else {
        _callRefreshToken();
      }
    }
  }

  void _removeSession() {
    currentSession = null;
    currentUser = null;

    if (_refreshTokenTimer != null) {
      _refreshTokenTimer!.cancel();
    }
  }

  Future<GotrueSessionResponse> _callRefreshToken({
    String? refreshToken,
  }) async {
    final token = refreshToken ?? currentSession?.refreshToken;
    if (token == null) {
      final error = GotrueError('No current session.');
      return GotrueSessionResponse(error: error);
    }

    final response = await api.refreshAccessToken(token);
    if (response.error != null) return response;
    if (response.data == null) {
      final error = GotrueError('Invalid session data.');
      return GotrueSessionResponse(error: error);
    }

    _saveSession(response.data!);
    _notifyAllSubscribers(AuthChangeEvent.tokenRefreshed);
    _notifyAllSubscribers(AuthChangeEvent.signedIn);

    return response;
  }

  void _notifyAllSubscribers(AuthChangeEvent event) {
    stateChangeEmitters.forEach((k, v) => v.callback(event, currentSession));
  }
}

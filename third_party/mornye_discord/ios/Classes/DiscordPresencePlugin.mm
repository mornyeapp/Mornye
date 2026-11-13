#import "DiscordPresencePlugin.h"

#ifdef MORNYE_DISCORD_SDK
#define DISCORDPP_IMPLEMENTATION
#include <discord_partner_sdk/discordpp.h>
#include <memory>
#endif

@implementation DiscordPresencePlugin {
    FlutterMethodChannel *_channel;
    NSTimer *_timer;
    FlutterResult _authResult;
    NSUInteger _generation;
#ifdef MORNYE_DISCORD_SDK
    std::unique_ptr<discordpp::Client> _client;
#endif
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    DiscordPresencePlugin *plugin = [[DiscordPresencePlugin alloc] init];
    plugin->_channel = [FlutterMethodChannel methodChannelWithName:@"com.zarz.mornye/discord"
                                                   binaryMessenger:registrar.messenger];
    [registrar addMethodCallDelegate:plugin channel:plugin->_channel];
}

- (void)status:(NSString *)value {
    [_channel invokeMethod:@"status" arguments:value];
}

- (void)finishAuth:(id)value {
    FlutterResult result = _authResult;
    _authResult = nil;
    if (result) result(value);
}

- (void)shutdown {
    ++_generation;
    [self finishAuth:[FlutterError errorWithCode:@"cancelled" message:@"Discord linking cancelled." details:nil]];
    [_timer invalidate];
    _timer = nil;
#ifdef MORNYE_DISCORD_SDK
    if (_client) {
        _client->AbortAuthorize();
        _client->ClearRichPresence();
        _client->Disconnect();
        discordpp::RunCallbacks();
        _client.reset();
    }
#endif
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
#ifndef MORNYE_DISCORD_SDK
    result([call.method isEqualToString:@"initialize"] ? @NO : nil);
#else
    NSDictionary *args = [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : @{};
    if ([call.method isEqualToString:@"initialize"]) {
        if (!_client) {
            _client = std::make_unique<discordpp::Client>();
            _client->SetApplicationId(1549854098801692862ULL);
            _client->SetEngineManagedAudioSession(true);
            __weak DiscordPresencePlugin *weakSelf = self;
            _client->SetStatusChangedCallback([weakSelf](discordpp::Client::Status status, discordpp::Client::Error, int32_t) {
                DiscordPresencePlugin *self = weakSelf;
                if (!self) return;
                [self status:status == discordpp::Client::Status::Ready ? @"ready" : @"connecting"];
            });
            _client->SetTokenExpirationCallback([weakSelf]() { [weakSelf status:@"expired"]; });
            _timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *) { discordpp::RunCallbacks(); }];
            [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
        }
        result(@YES);
        return;
    }
    if ([call.method isEqualToString:@"shutdown"]) { [self shutdown]; result(nil); return; }
    if (!_client) { result([FlutterError errorWithCode:@"not_initialized" message:@"Discord is disabled." details:nil]); return; }

    if ([call.method isEqualToString:@"authorize"] || [call.method isEqualToString:@"refresh"]) {
        if (_authResult) { result([FlutterError errorWithCode:@"busy" message:@"Discord linking is in progress." details:nil]); return; }
        _authResult = [result copy];
        const auto generation = _generation;
        __weak DiscordPresencePlugin *weakSelf = self;
        auto exchanged = [weakSelf, generation](discordpp::ClientResult response, std::string access,
            std::string refresh, discordpp::AuthorizationTokenType, int32_t expires, std::string) {
            DiscordPresencePlugin *self = weakSelf;
            if (!self || self->_generation != generation) return;
            if (!response.Successful()) {
                [self finishAuth:[FlutterError errorWithCode:@"authorization_failed" message:@"Discord authorization failed. Please try again." details:nil]];
                return;
            }
            [self finishAuth:@{@"access": @(access.c_str()), @"refresh": @(refresh.c_str()), @"expiresIn": @(expires)}];
        };
        if ([call.method isEqualToString:@"refresh"]) {
            _client->RefreshToken(1549854098801692862ULL, [args[@"refresh"] UTF8String], exchanged);
        } else {
            auto verifier = _client->CreateAuthorizationCodeVerifier();
            discordpp::AuthorizationArgs auth;
            auth.SetClientId(1549854098801692862ULL);
            auth.SetScopes(discordpp::Client::GetDefaultPresenceScopes());
            auth.SetCodeChallenge(verifier.Challenge());
            _client->Authorize(auth, [weakSelf, generation, verifier, exchanged](discordpp::ClientResult response, std::string code, std::string redirect) {
                DiscordPresencePlugin *self = weakSelf;
                if (!self || self->_generation != generation || !self->_client) return;
                if (!response.Successful()) {
                    [self finishAuth:[FlutterError errorWithCode:@"cancelled" message:@"Discord linking was cancelled or unavailable." details:nil]];
                    return;
                }
                self->_client->GetToken(1549854098801692862ULL, code, verifier.Verifier(), redirect, exchanged);
            });
        }
    } else if ([call.method isEqualToString:@"connect"]) {
        const auto generation = _generation;
        __weak DiscordPresencePlugin *weakSelf = self;
        _client->UpdateToken(discordpp::AuthorizationTokenType::Bearer, [args[@"access"] UTF8String],
            [weakSelf, generation](discordpp::ClientResult response) {
                DiscordPresencePlugin *self = weakSelf;
                if (!self || self->_generation != generation || !self->_client) return;
                if (response.Successful()) self->_client->Connect();
                else [self status:@"unavailable"];
            });
        result(nil);
    } else if ([call.method isEqualToString:@"update"]) {
        discordpp::Activity activity;
        activity.SetName([args[@"state"] UTF8String]);
        activity.SetType(discordpp::ActivityTypes::Listening);
        activity.SetDetails([args[@"title"] UTF8String]);
        activity.SetState([args[@"state"] UTF8String]);
        if ([args[@"artwork"] length]) {
            discordpp::ActivityAssets assets;
            assets.SetLargeImage([args[@"artwork"] UTF8String]);
            activity.SetAssets(assets);
        }
        discordpp::ActivityTimestamps timestamps;
        if ([args[@"start"] unsignedLongLongValue]) timestamps.SetStart([args[@"start"] unsignedLongLongValue]);
        if ([args[@"end"] unsignedLongLongValue]) timestamps.SetEnd([args[@"end"] unsignedLongLongValue]);
        activity.SetTimestamps(timestamps);
        const auto generation = _generation;
        __weak DiscordPresencePlugin *weakSelf = self;
        _client->UpdateRichPresence(activity, [weakSelf, generation](discordpp::ClientResult response) {
            DiscordPresencePlugin *self = weakSelf;
            if (self && self->_generation == generation) [self status:response.Successful() ? @"active" : @"unavailable"];
        });
        result(nil);
    } else if ([call.method isEqualToString:@"clear"]) {
        _client->ClearRichPresence();
        result(nil);
    } else {
        result(FlutterMethodNotImplemented);
    }
#endif
}

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    [self shutdown];
}
@end

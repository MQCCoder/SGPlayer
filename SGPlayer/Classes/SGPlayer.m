//
//  SGPlayer.m
//  SGPlayer
//
//  Created by Single on 03/01/2017.
//  Copyright © 2017 single. All rights reserved.
//

#import "SGPlayer.h"
#import "SGMacro.h"
#import "SGActivity.h"
#import "SGSession.h"
#import "SGURLSource.h"
#import "SGConcatSource.h"
#import "SGAudioDecoder.h"
#import "SGVideoDecoder.h"
#import "SGAudioPlaybackOutput.h"
#import "SGVideoPlaybackOutput.h"

@interface SGPlayer () <NSLocking>

@property (nonatomic, strong, readonly) SGAsset * asset;
@property (nonatomic, strong, readonly) NSError * error;
@property (nonatomic, assign, readonly) SGPrepareState prepareState;
@property (nonatomic, assign, readonly) SGPlaybackState playbackState;
@property (nonatomic, assign, readonly) SGLoadingState loadingState;
@property (nonatomic, assign, readonly) CMTime time;
@property (nonatomic, assign, readonly) CMTime loadedTime;
@property (nonatomic, assign, readonly) CMTime duration;
@property (nonatomic, assign) CMTime rate;
@property (nonatomic, assign) float volume;
@property (nonatomic, assign) CMTime deviceDelay;
@property (nonatomic, strong) UIView * view;
@property (nonatomic, assign) SGScalingMode scalingMode;
@property (nonatomic, assign) SGDisplayMode displayMode;
@property (nonatomic, strong) SGVRViewport * viewport;
@property (nonatomic, copy) void (^displayCallback)(SGVideoFrame * frame);
@property (nonatomic, copy) NSDictionary * formatContextOptions;
@property (nonatomic, copy) NSDictionary * codecContextOptions;
@property (nonatomic, assign) BOOL threadsAuto;
@property (nonatomic, assign) BOOL refcountedFrames;
@property (nonatomic, assign) BOOL hardwareDecodeH264;
@property (nonatomic, assign) BOOL hardwareDecodeH265;
@property (nonatomic, weak) id <SGPlayerDelegate> delegate;
@property (nonatomic, strong) NSOperationQueue * delegateQueue;

@end

@interface SGPlayer () <SGSessionDelegate>

@property (nonatomic, strong) NSLock * coreLock;
@property (nonatomic, strong) SGSession * session;
@property (nonatomic, strong) SGAudioPlaybackOutput * audioOutput;
@property (nonatomic, strong) SGVideoPlaybackOutput * videoOutput;
@property (nonatomic, assign) NSUInteger seekingToken;
@property (nonatomic, assign) CMTime lastTime;
@property (nonatomic, assign) CMTime lastLoadedTime;
@property (nonatomic, assign) CMTime lastDuration;

@end

@implementation SGPlayer

- (instancetype)init
{
    if (self = [super init])
    {
        self.rate = CMTimeMake(1, 1);
        self.volume = 1.0;
        self.deviceDelay = CMTimeMake(1, 20);
        self.scalingMode = SGScalingModeResizeAspect;
        self.displayMode = SGDisplayModePlane;
        self.viewport = [[SGVRViewport alloc] init];
        self.formatContextOptions = @{@"user-agent" : @"SGPlayer",
                                      @"timeout" : @(20 * 1000 * 1000),
                                      @"reconnect" : @(1)};
        self.codecContextOptions = nil;
        self.threadsAuto = YES;
        self.refcountedFrames = YES;
        self.hardwareDecodeH264 = YES;
        self.hardwareDecodeH265 = YES;
        self.delegateQueue = [NSOperationQueue mainQueue];
        [self destory];
    }
    return self;
}

- (void)dealloc
{
    [self destory];
}

#pragma mark - Asset

- (void)replaceWithURL:(NSURL *)URL
{
    [self replaceWithAsset:[[SGURLAsset alloc] initWithURL:URL]];
}

- (void)replaceWithAsset:(SGAsset *)asset
{
    [self stop];
    SGConcatAsset * concatAsset = [self concatAssetWithAsset:asset];
    if (!concatAsset)
    {
        return;
    }
    _asset = concatAsset;
    
    SGConcatSource * source = [[SGConcatSource alloc] initWithAsset:concatAsset];
    source.options = self.formatContextOptions;
    
    SGAudioDecoder * audioDecoder = [[SGAudioDecoder alloc] init];
    audioDecoder.options = self.codecContextOptions;
    audioDecoder.threadsAuto = self.threadsAuto;
    audioDecoder.refcountedFrames = self.refcountedFrames;
    
    SGVideoDecoder * videoDecoder = [[SGVideoDecoder alloc] init];
    videoDecoder.options = self.codecContextOptions;
    videoDecoder.threadsAuto = self.threadsAuto;
    videoDecoder.refcountedFrames = self.refcountedFrames;
    videoDecoder.hardwareDecodeH264 = self.hardwareDecodeH264;
    videoDecoder.hardwareDecodeH265 = self.hardwareDecodeH265;
    
    SGAudioPlaybackOutput * auidoOutput = [[SGAudioPlaybackOutput alloc] init];
    auidoOutput.timeSync = [[SGPlaybackTimeSync alloc] init];
    auidoOutput.rate = self.rate;
    auidoOutput.volume = self.volume;
    self.deviceDelay = self.deviceDelay;
    self.audioOutput = auidoOutput;
    
    SGVideoPlaybackOutput * videoOutput = [[SGVideoPlaybackOutput alloc] init];
    videoOutput.timeSync = self.audioOutput.timeSync;
    videoOutput.rate = self.rate;
    videoOutput.view = self.view;
    videoOutput.scalingMode = self.scalingMode;
    videoOutput.displayMode = self.displayMode;
    videoOutput.displayCallback = self.displayCallback;
    videoOutput.viewport = self.viewport;
    self.videoOutput = videoOutput;
    
    SGSessionConfiguration * configuration = [[SGSessionConfiguration alloc] init];
    configuration.source = source;
    configuration.audioDecoder = audioDecoder;
    configuration.videoDecoder = videoDecoder;
    configuration.audioOutput = auidoOutput;
    configuration.videoOutput = videoOutput;
    
    SGSession * session = [[SGSession alloc] initWithConfiguration:configuration];
    session.delegate = self;
    self.session = session;
    
    [self lock];
    SGBasicBlock prepareCallback = [self setPrepareState:SGPrepareStatePreparing];
    [self unlock];
    prepareCallback();
    
    [self.session open];
}

- (SGConcatAsset *)concatAssetWithAsset:(SGAsset *)asset
{
    if (!asset)
    {
        return nil;
    }
    SGConcatAsset * concatAsset = nil;
    if ([asset isKindOfClass:[SGURLAsset class]])
    {
        concatAsset = [[SGConcatAsset alloc] initWithAssets:@[(SGURLAsset *)asset]];
    }
    else if ([asset isKindOfClass:[SGConcatAsset class]])
    {
        concatAsset = (SGConcatAsset *)asset;
    }
    if (!concatAsset)
    {
        return nil;
    }
    BOOL error = NO;
    for (SGURLAsset * obj in concatAsset.assets)
    {
        if (!obj.URL)
        {
            error = YES;
            break;
        }
    }
    if (error)
    {
        return nil;
    }
    return concatAsset;
}

#pragma mark - State

- (SGBasicBlock)setPrepareState:(SGPrepareState)prepareState
{
    if (_prepareState != prepareState)
    {
        _prepareState = prepareState;
        return ^{
            [self playAndPause];
            [self callbackForTimingIfNeeded];
            [self callback:^{
                [self.delegate playerDidChangePrepareState:self];
            }];
        };
    }
    return ^{};
}

- (SGBasicBlock)setPlaybackState:(SGPlaybackState)playbackState
{
    if (_playbackState != playbackState)
    {
        _playbackState = playbackState;
        return ^{
            [self playAndPause];
            [self callbackForTimingIfNeeded];
            [self callback:^{
                [self.delegate playerDidChangePlaybackState:self];
            }];
        };
    }
    return ^{};
}

- (SGBasicBlock)setLoadingState:(SGLoadingState)loadingState
{
    if (_loadingState != loadingState)
    {
        _loadingState = loadingState;
        return ^{
            [self playAndPause];
            [self callbackForTimingIfNeeded];
            [self callback:^{
                [self.delegate playerDidChangeLoadingState:self];
            }];
        };
    }
    return ^{};
}

#pragma mark - Timing

- (CMTime)time
{
    if (self.session.state == SGSessionStateFinished && self.session.empty)
    {
        return self.duration;
    }
    if (self.audioOutput.timeSync)
    {
        return self.audioOutput.timeSync.time;
    }
    return kCMTimeZero;
}

- (CMTime)loadedTime
{
    if (self.session.state == SGSessionStateFinished)
    {
        return self.duration;
    }
    CMTime time = self.time;
    CMTime loadedDuration = self.loadedDuration;
    CMTime duration = self.duration;
    CMTime loadedTime = CMTimeAdd(time, loadedDuration);
    return CMTimeMinimum(loadedTime, duration);
}

- (CMTime)duration
{
    if (self.session)
    {
        return self.session.duration;
    }
    return kCMTimeZero;
}

- (CMTime)loadedDuration
{
    if (self.session)
    {
        return self.session.loadedDuration;
    }
    return kCMTimeZero;
}

#pragma mark - Playback

- (void)setRate:(CMTime)rate
{
    if (CMTimeCompare(_rate, rate) != 0)
    {
        _rate = rate;
        self.audioOutput.rate = rate;
        self.videoOutput.rate = rate;
    }
}

- (BOOL)play
{
    [SGActivity addTarget:self];
    [self lock];
    if (self.error)
    {
        [self unlock];
        return NO;
    }
    if (self.playbackState == SGPlaybackStateFinished ||
        self.playbackState == SGPlaybackStateFailed)
    {
        [self unlock];
        return NO;
    }
    SGBasicBlock callback = [self setPlaybackState:SGPlaybackStatePlaying];
    [self unlock];
    callback();
    return YES;
}

- (BOOL)pause
{
    [SGActivity removeTarget:self];
    [self lock];
    if (self.error)
    {
        [self unlock];
        return NO;
    }
    if (self.playbackState == SGPlaybackStateFinished ||
        self.playbackState == SGPlaybackStateFailed)
    {
        [self unlock];
        return NO;
    }
    SGBasicBlock callback = [self setPlaybackState:SGPlaybackStatePaused];
    [self unlock];
    callback();
    return YES;
}

- (BOOL)stop
{
    [self destory];
    [self lock];
    SGBasicBlock prepareCallback = [self setPrepareState:SGPrepareStateNone];
    SGBasicBlock playbackCallback = [self setPlaybackState:SGPlaybackStateNone];
    SGBasicBlock loadingCallback = [self setLoadingState:SGLoadingStateNone];
    [self unlock];
    prepareCallback();
    playbackCallback();
    loadingCallback();
    return YES;
}

- (BOOL)seeking
{
    [self lock];
    BOOL ret = self.seekingToken != 0;
    [self unlock];
    return ret;
}

- (BOOL)seekable
{
    return self.session.seekable;
}

- (BOOL)seekableToTime:(CMTime)time
{
    return [self.session seekableToTime:time];
}

- (BOOL)seekToTime:(CMTime)time
{
    return [self seekToTime:time completionHandler:nil];
}

- (BOOL)seekToTime:(CMTime)time completionHandler:(void (^)(BOOL, CMTime))completionHandler
{
    if (![self seekableToTime:time])
    {
        return NO;
    }
    [self lock];
    if (self.error)
    {
        [self unlock];
        return NO;
    }
    self.seekingToken++;
    NSInteger seekingToken = self.seekingToken;
    [self unlock];
    SGWeakSelf
    [self.session seekToTime:time completionHandler:^(BOOL success, CMTime time) {
        SGStrongSelf
        [self lock];
        if (seekingToken == self.seekingToken)
        {
            self.seekingToken = 0;
        }
        [self unlock];
        if (completionHandler)
        {
            [self callback:^{
                completionHandler(success, time);
            }];
        }
    }];
    return YES;
}

#pragma mark - Audio

- (void)setVolume:(float)volume
{
    if (_volume != volume)
    {
        _volume = volume;
        self.audioOutput.volume = _volume;
    }
}

- (void)setDeviceDelay:(CMTime)deviceDelay
{
    if (CMTimeCompare(_deviceDelay, deviceDelay) != 0)
    {
        _deviceDelay = deviceDelay;
        self.audioOutput.deviceDelay = deviceDelay;
    }
}

#pragma mark - Video

- (void)setView:(UIView *)view
{
    if (_view != view)
    {
        _view = view;
        self.videoOutput.view = _view;
    }
}

- (void)setScalingMode:(SGScalingMode)scalingMode
{
    if (_scalingMode != scalingMode)
    {
        _scalingMode = scalingMode;
        self.videoOutput.scalingMode = scalingMode;
    }
}

- (void)setDisplayMode:(SGDisplayMode)displayMode
{
    if (_displayMode != displayMode)
    {
        _displayMode = displayMode;
        self.videoOutput.displayMode = displayMode;
    }
}

- (void)setViewport:(SGVRViewport *)viewport
{
    if (_viewport != viewport)
    {
        _viewport = viewport;
        self.videoOutput.viewport = viewport;
    }
}

- (void)setDisplayCallback:(void (^)(SGVideoFrame *))displayCallback
{
    if (_displayCallback != displayCallback)
    {
        _displayCallback = displayCallback;
        self.videoOutput.displayCallback = displayCallback;
    }
}

- (UIImage *)originalImage
{
    return self.videoOutput.originalImage;
}

- (UIImage *)snapshot
{
    return self.videoOutput.snapshot;
}

#pragma mark - Track

#pragma mark - FormatContext

#pragma mark - CodecContext

#pragma mark - Delegate

- (void)callback:(void (^)(void))block
{
    if (!block)
    {
        return;
    }
    if (self.delegateQueue)
    {
        NSOperation * operation = [NSBlockOperation blockOperationWithBlock:^{
            block();
        }];
        [self.delegateQueue addOperation:operation];
    }
    else
    {
        block();
    }
}

- (void)callbackForTimingIfNeeded
{
    if (self.audioOutput.enable && !self.audioOutput.receivedFrame)
    {
        return;
    }
    if (self.videoOutput.enable && !self.videoOutput.receivedFrame)
    {
        return;
    }
    [self lock];
    if (self.error)
    {
        [self unlock];
        return;
    }
    [self unlock];
    CMTime time = self.time;
    CMTime loadedTime = self.loadedTime;
    CMTime duration = self.duration;
    if (CMTimeCompare(time, self.lastTime) != 0 ||
        CMTimeCompare(loadedTime, self.lastLoadedTime) != 0 ||
        CMTimeCompare(duration, self.lastDuration) != 0)
    {
        self.lastTime = time;
        self.lastLoadedTime = loadedTime;
        self.lastDuration = duration;
        [self callback:^{
            [self.delegate playerDidChangeTimingInfo:self];
        }];
    }
}

#pragma mark - Internal

- (void)playAndPause
{
    [self lock];
    BOOL playback = self.playbackState == SGPlaybackStatePlaying;
    BOOL loading = self.loadingState == SGLoadingStateLoading || self.loadingState == SGLoadingStateFinished;
    BOOL data = !self.session.empty;
    [self unlock];
    if (playback && loading && data)
    {
        [self.audioOutput resume];
        [self.videoOutput resume];
    }
    else
    {
        [self.audioOutput pause];
        [self.videoOutput pause];
    }
}

- (void)destory
{
    [SGActivity removeTarget:self];
    [self.session close];
    self.session = nil;
    self.audioOutput = nil;
    self.videoOutput = nil;
    self.lastTime = CMTimeMake(-1900, 1);
    self.lastLoadedTime = CMTimeMake(-1900, 1);
    self.lastDuration = CMTimeMake(-1900, 1);
    _asset = nil;
    _error = nil;
}

#pragma mark - SGSessionDelegate

- (void)sessionDidChangeState:(SGSession *)session
{
    if (session.state == SGSessionStateOpened)
    {
        [session read];
        [self lock];
        SGBasicBlock prepareCallback = [self setPrepareState:SGPrepareStateFinished];
        SGBasicBlock loadingCallback = [self setLoadingState:SGLoadingStateLoading];
        [self unlock];
        prepareCallback();
        loadingCallback();
    }
    else if (session.state == SGSessionStateFailed)
    {
        [self lock];
        _error =  session.error;
        SGBasicBlock prepareCallback = [self setPrepareState:SGPrepareStateFailed];
        SGBasicBlock playbackCallback = [self setPlaybackState:SGPlaybackStateFailed];
        SGBasicBlock loadingCallback = [self setLoadingState:SGLoadingStateFailed];
        [self unlock];
        prepareCallback();
        playbackCallback();
        loadingCallback();
    }
}

- (void)sessionDidChangeCapacity:(SGSession *)session
{
    if (self.session.state == SGSessionStateFinished)
    {
        [self lock];
        SGBasicBlock loadingCallback = [self setLoadingState:SGLoadingStateFinished];
        [self unlock];
        loadingCallback();
    }
    if (self.session.state == SGSessionStateFinished && self.session.empty)
    {
        [self lock];
        SGBasicBlock playbackCallback = [self setPlaybackState:SGPlaybackStateFinished];
        [self unlock];
        playbackCallback();
    }
    [self playAndPause];
    [self callbackForTimingIfNeeded];
}

#pragma mark - NSLocking

- (void)lock
{
    if (!self.coreLock)
    {
        self.coreLock = [[NSLock alloc] init];
    }
    [self.coreLock lock];
}

- (void)unlock
{
    [self.coreLock unlock];
}

@end

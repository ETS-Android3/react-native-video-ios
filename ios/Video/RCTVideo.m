#import <React/RCTConvert.h>
#import "RCTVideo.h"
#import <React/RCTBridgeModule.h>
#import <React/RCTEventDispatcher.h>
#import <React/UIView+React.h>
#include <MediaAccessibility/MediaAccessibility.h>
#include <AVFoundation/AVFoundation.h>
#import <YouboraAVPlayerAdapter/YouboraAVPlayerAdapter.h>
#import <GoogleInteractiveMediaAds/GoogleInteractiveMediaAds.h>


@interface CustomAdapter : YBAVPlayerAdapter
@property NSDictionary *customArguments;
@end

@implementation CustomAdapter

- (void)fireJoin {
    [super fireJoin:self.customArguments];
}
- (void)fireStart {
    [super fireStart:self.customArguments];
}
- (void)fireStop:(NSDictionary<NSString *,NSString *> *)params {
    
    [super fireStop:params];
    self.supportPlaylists = NO;
}
@end


@interface RCTVideo () <IMAAdsLoaderDelegate, IMAStreamManagerDelegate>
@end

static NSString *const statusKeyPath = @"status";
static NSString *const playbackLikelyToKeepUpKeyPath = @"playbackLikelyToKeepUp";
static NSString *const playbackBufferEmptyKeyPath = @"playbackBufferEmpty";
static NSString *const readyForDisplayKeyPath = @"readyForDisplay";
static NSString *const playbackRate = @"rate";
static NSString *const timedMetadata = @"timedMetadata";
static NSString *const externalPlaybackActive = @"externalPlaybackActive";

static int const RCTVideoUnset = -1;

#ifdef DEBUG
#define DebugLog(...) NSLog(__VA_ARGS__)
#else
#define DebugLog(...) (void)0
#endif

@implementation RCTVideo
{
    AVPlayer *_player;
    AVPlayerItem *_playerItem;
    NSDictionary *_source;
    BOOL _playerItemObserversSet;
    BOOL _playerBufferEmpty;
    AVPlayerLayer *_playerLayer;
    BOOL _playerLayerObserverSet;
    RCTVideoPlayerViewController *_playerViewController;
    NSURL *_videoURL;
    BOOL _requestingCertificate;
    BOOL _requestingCertificateErrored;
    
    /* DRM */
    NSDictionary *_drm;
    AVAssetResourceLoadingRequest *_loadingRequest;
    
    /* Required to publish events */
    RCTEventDispatcher *_eventDispatcher;
    BOOL _playbackRateObserverRegistered;
    BOOL _isExternalPlaybackActiveObserverRegistered;
    BOOL _videoLoadStarted;
    
    bool _pendingSeek;
    float _pendingSeekTime;
    float _lastSeekTime;
    
    /* For sending videoProgress events */
    Float64 _progressUpdateInterval;
    BOOL _controls;
    id _timeObserver;
    
    /* Keep track of any modifiers, need to be applied after each play */
    float _volume;
    float _rate;
    float _maxBitRate;
    
    BOOL _automaticallyWaitsToMinimizeStalling;
    BOOL _muted;
    BOOL _paused;
    BOOL _repeat;
    BOOL _allowsExternalPlayback;
    NSArray * _textTracks;
    NSDictionary * _selectedTextTrack;
    NSDictionary * _selectedAudioTrack;
    BOOL _playbackStalled;
    BOOL _playInBackground;
    BOOL _playWhenInactive;
    BOOL _pictureInPicture;
    NSString * _ignoreSilentSwitch;
    NSString * _resizeMode;
    BOOL _fullscreen;
    BOOL _fullscreenAutorotate;
    NSString * _fullscreenOrientation;
    BOOL _fullscreenPlayerPresented;
    NSString *_filterName;
    BOOL _filterEnabled;
    UIViewController * _presentingViewController;
    NSDictionary *_shahidYouboraOptions;
    YBPlugin * _youboraPlugin;
    CustomAdapter * _adapter;
    
    // google IMA DAI vars
    IMAAdsLoader *adsLoader;
    UIView *adContainerView;
    IMAStreamManager *streamManager;
    NSArray<IMACuepoint *> *_cuepoints;
    BOOL adPlaying;
    BOOL _disableAds;
    NSNumber *snapbackTime;
    
#if __has_include(<react-native-video/RCTVideoCache.h>)
    RCTVideoCache * _videoCache;
#endif
#if TARGET_OS_IOS
    void (^__strong _Nonnull _restoreUserInterfaceForPIPStopCompletionHandler)(BOOL);
    AVPictureInPictureController *_pipController;
#endif
}

- (instancetype)initWithEventDispatcher:(RCTEventDispatcher *)eventDispatcher
{
    if ((self = [super init])) {
        _eventDispatcher = eventDispatcher;
        _automaticallyWaitsToMinimizeStalling = YES;
        _playbackRateObserverRegistered = NO;
        _isExternalPlaybackActiveObserverRegistered = NO;
        _playbackStalled = NO;
        _rate = 1.0;
        _volume = 1.0;
        _resizeMode = @"AVLayerVideoGravityResizeAspectFill";
        _fullscreenAutorotate = YES;
        _fullscreenOrientation = @"all";
        _pendingSeek = false;
        _pendingSeekTime = 0.0f;
        _lastSeekTime = 0.0f;
        _progressUpdateInterval = 250;
        _controls = NO;
        _playerBufferEmpty = YES;
        _playInBackground = false;
        _allowsExternalPlayback = YES;
        _playWhenInactive = false;
        _pictureInPicture = false;
        _ignoreSilentSwitch = @"inherit"; // inherit, ignore, obey
        _disableAds = false;
#if TARGET_OS_IOS
        _restoreUserInterfaceForPIPStopCompletionHandler = NULL;
#endif
#if __has_include(<react-native-video/RCTVideoCache.h>)
        _videoCache = [RCTVideoCache sharedInstance];
#endif
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillResignActive:)
                                                     name:UIApplicationWillResignActiveNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidEnterBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillEnterForeground:)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(audioRouteChanged:)
                                                     name:AVAudioSessionRouteChangeNotification
                                                   object:nil];
    }
    
    return self;
}

- (void)setupAdsLoader {
    //    IMASettings* settings = [[IMASettings alloc] init];
    //    settings.enableDebugMode = YES;
    //    self->adsLoader = [[IMAAdsLoader alloc] initWithSettings:settings];
    self->adPlaying = false;
    self->adsLoader = [[IMAAdsLoader alloc] init];
    self->adsLoader.delegate = self;
}

- (void)attachAdContainer {
    self->adContainerView = [[UIView alloc] init];
    [self addSubview:self->adContainerView];
    self->adContainerView.frame = self.bounds;
    self->adContainerView.hidden = YES;
}

- (void) requestStream:(NSString *)kContentSourceID kVideoID:(NSString *) kVideoID{
    if (self->adsLoader == NULL) {
        [self setupAdsLoader];
        [self attachAdContainer];
        
        IMAAVPlayerVideoDisplay *videoDisplay = [[IMAAVPlayerVideoDisplay alloc] initWithAVPlayer:self->_player];
        
        IMAAdDisplayContainer *adDisplayContainer = [[IMAAdDisplayContainer alloc]
                                                     initWithAdContainer:self->adContainerView
                                                     viewController: self.reactViewController];
        
        IMAVODStreamRequest *request = [[IMAVODStreamRequest alloc] initWithContentSourceID:kContentSourceID
                                                                                    videoID:kVideoID
                                                                         adDisplayContainer:adDisplayContainer
                                                                               videoDisplay:videoDisplay];
        [self->adsLoader requestStreamWithRequest:request];
    }
}

- (void)playBackupStream {
    self->_disableAds = true;
    [self setSrc: _source];
}

#pragma mark - IMAAdsLoaderDelegate

- (void)adsLoader:(IMAAdsLoader *)loader adsLoadedWithData:(IMAAdsLoadedData *)adsLoadedData {
    // Initialize and listen to stream manager's events.
    self->streamManager = adsLoadedData.streamManager;
    self->streamManager.delegate = self;
    [self->streamManager initializeWithAdsRenderingSettings:nil];
    //    NSLog(@"saffar Stream created with: %@.", self->streamManager.streamId);
    
    [self usePlayerLayer];
    [self attachListeners];
}

- (void)adsLoader:(IMAAdsLoader *)loader failedWithErrorData:(IMAAdLoadingErrorData *)adErrorData {
    // Fall back to playing the backup stream.
    [self playBackupStream];
}

#pragma mark - IMAStreamManagerDelegate

- (void)streamManager:(IMAStreamManager *)streamManager didReceiveAdEvent:(IMAAdEvent *)event {
//    NSLog(@"saffar StreamManager event (%@).", event.typeString);
    switch (event.type) {
//        case kIMAAdEvent_STARTED: {
//            // Log extended data.
//            NSString *extendedAdPodInfo = [[NSString alloc]
//                                           initWithFormat:@"Showing ad %zd/%zd, bumper: %@, title: %@, description: %@, contentType:"
//                                           @"%@, pod index: %zd, time offset: %lf, max duration: %lf.",
//                                           event.ad.adPodInfo.adPosition, event.ad.adPodInfo.totalAds,
//                                           event.ad.adPodInfo.isBumper ? @"YES" : @"NO", event.ad.adTitle,
//                                           event.ad.adDescription, event.ad.contentType, event.ad.adPodInfo.podIndex,
//                                           event.ad.adPodInfo.timeOffset, event.ad.adPodInfo.maxDuration];
//
//            NSLog(@"saffar STARTED %@", extendedAdPodInfo);
//            break;
//        }
//        case kIMAAdEvent_COMPLETE: {
//
//        }
        case kIMAAdEvent_CUEPOINTS_CHANGED: {
            if (self->_cuepoints == NULL) {
                self->_cuepoints = [event.adData objectForKey:@"cuepoints"];
            }
        }
        case kIMAAdEvent_AD_BREAK_STARTED: {
            // Prevent user seek through when an ad starts.
            //            self->_playerViewController.requiresLinearPlayback = YES;
            self->adPlaying = true;
            if (self.onAdEvent) {
                self.onAdEvent(@{@"type": @"AdBreakStarted"});
            }
            
//            NSLog(@"saffar playedAd %f %f",CMTimeGetSeconds(self->_player.currentTime),event.ad.duration);
            break;
        }
        case kIMAAdEvent_AD_BREAK_ENDED: {
            // Allow users to seek through after an ad ends.
            //            self->_playerViewController.requiresLinearPlayback = NO;
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        //            BOOL isSeeking = false;
                        if (self->snapbackTime) {
                            [self setSeek:@{@"time": self->snapbackTime}];
                            self->snapbackTime = NULL;
            //                isSeeking = true;
                        }
                    });
            
            self->adPlaying = false;
            if (self.onAdEvent) {
                self.onAdEvent(@{
                    @"type": @"AdBreakEnded",
//                    @"data": @{@"isSeeking": [NSNumber numberWithBool:isSeeking]}
                               });
            }
        }
            //                    case kIMAAdEvent_STREAM_LOADED: { }
            //                    case kIMAAdEvent_AD_PERIOD_ENDED: {
            //                        NSLog(@"saffar playedAd %@",event.adData);
            //                    }
            //                    case kIMAAdEvent_AD_PERIOD_STARTED: {
            //                        NSLog(@"saffar playedAd %@",event.adData);
            //
            //                    }
        default:
            break;
    }
}

- (void)streamManager:(IMAStreamManager *)streamManager didReceiveAdError:(IMAAdError *)error {
    // Fall back to playing the backup stream.
    NSLog(@"saffar StreamManager error: %@", error.message);
    [self playBackupStream];
}

- (void)streamManager:(IMAStreamManager *)streamManager
  adDidProgressToTime:(NSTimeInterval)time
           adDuration:(NSTimeInterval)adDuration
           adPosition:(NSInteger)adPosition
             totalAds:(NSInteger)totalAds
      adBreakDuration:(NSTimeInterval)adBreakDuration {
    
    if (self.onAdEvent) {
        self.onAdEvent(@{
            @"type": @"AdProgress",
            @"data": @{
                    @"currentPosition": [NSNumber numberWithInt:(int)adPosition],
                    @"totalCount": [NSNumber numberWithInt:(int)totalAds],
                    @"remainingTime": [NSNumber numberWithInt:(int)(adDuration - time)],
                    @"progress":  [NSString stringWithFormat:@"%f%%", time / adDuration * 100]
            }
                       });
    }
}

- (void)stop
{
    dispatch_sync(dispatch_get_main_queue(), ^{
        //        [self->_player pause];
        //         self->_playerItem = nil;
        //        [self->_player replaceCurrentItemWithPlayerItem:nil];
        //        self->_player = nil;
        [self->_adapter fireStop];
    });
}
- (RCTVideoPlayerViewController*)createPlayerViewController:(AVPlayer*)player
                                             withPlayerItem:(AVPlayerItem*)playerItem {
    RCTVideoPlayerViewController* viewController = [[RCTVideoPlayerViewController alloc] init];
    viewController.showsPlaybackControls = YES;
    viewController.rctDelegate = self;
    viewController.preferredOrientation = _fullscreenOrientation;
    
    viewController.view.frame = self.bounds;
    viewController.player = player;
    return viewController;
}

/* ---------------------------------------------------------
 **  Get the duration for a AVPlayerItem.
 ** ------------------------------------------------------- */

- (CMTime)playerItemDuration
{
    AVPlayerItem *playerItem = [_player currentItem];
    if (playerItem.status == AVPlayerItemStatusReadyToPlay)
    {
        return([playerItem duration]);
    }
    
    return(kCMTimeInvalid);
}

- (CMTimeRange)playerItemSeekableTimeRange
{
    AVPlayerItem *playerItem = [_player currentItem];
    if (playerItem.status == AVPlayerItemStatusReadyToPlay)
    {
        return [playerItem seekableTimeRanges].firstObject.CMTimeRangeValue;
    }
    
    return (kCMTimeRangeZero);
}

-(void)addPlayerTimeObserver
{
    const Float64 progressUpdateIntervalMS = _progressUpdateInterval / 1000;
    // @see endScrubbing in AVPlayerDemoPlaybackViewController.m
    // of https://developer.apple.com/library/ios/samplecode/AVPlayerDemo/Introduction/Intro.html
    __weak RCTVideo *weakSelf = self;
    _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(progressUpdateIntervalMS, NSEC_PER_SEC)
                                                          queue:NULL
                                                     usingBlock:^(CMTime time) { [weakSelf sendProgressUpdate]; }
                     ];
}

/* Cancels the previously registered time observer. */
-(void)removePlayerTimeObserver
{
    if (_timeObserver)
    {
        [_player removeTimeObserver:_timeObserver];
        _timeObserver = nil;
    }
}

#pragma mark - Progress

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self removePlayerLayer];
    [self removePlayerItemObservers];
    [_player removeObserver:self forKeyPath:playbackRate context:nil];
    [_player removeObserver:self forKeyPath:externalPlaybackActive context: nil];
}

#pragma mark - App lifecycle handlers

- (void)applicationWillResignActive:(NSNotification *)notification
{
    if (_playInBackground || _playWhenInactive || _paused) return;
    
    [_player pause];
    [_player setRate:0.0];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
    if (_playInBackground) {
        // Needed to play sound in background. See https://developer.apple.com/library/ios/qa/qa1668/_index.html
        [_playerLayer setPlayer:nil];
        [_playerViewController setPlayer:nil];
    }
}

- (void)applicationWillEnterForeground:(NSNotification *)notification
{
    [self applyModifiers];
    if (_playInBackground) {
        [_playerLayer setPlayer:_player];
        [_playerViewController setPlayer:_player];
    }
}

#pragma mark - Audio events

- (void)audioRouteChanged:(NSNotification *)notification
{
    NSNumber *reason = [[notification userInfo] objectForKey:AVAudioSessionRouteChangeReasonKey];
    //    NSNumber *previousRoute = [[notification userInfo] objectForKey:AVAudioSessionRouteChangePreviousRouteKey];
    if (reason.unsignedIntValue == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
        self.onVideoAudioBecomingNoisy(@{@"target": self.reactTag});
    }
}

#pragma mark - Progress

- (void)sendProgressUpdate
{
    AVPlayerItem *video = [_player currentItem];
    if (video == nil || video.status != AVPlayerItemStatusReadyToPlay || self->adPlaying) {
        return;
    }
    
    CMTime playerDuration = [self playerItemDuration];
    //    CMTime playerDuration = [video duration]; // saffar minor optimization
    if (CMTIME_IS_INVALID(playerDuration)) {
        return;
    }
    
    CMTime currentTime = _player.currentTime;
    const Float64 duration = CMTimeGetSeconds(playerDuration);
    const Float64 currentTimeSecs = CMTimeGetSeconds(currentTime);
    
    if (self->streamManager) {
        IMACuepoint *previousCuepoint = [self->streamManager previousCuepointForStreamTime: currentTimeSecs + 0.2];
        
        if (previousCuepoint && previousCuepoint.played && previousCuepoint.endTime > currentTimeSecs) {
            [self setSeek:@{@"time": [NSNumber numberWithFloat:[self->streamManager contentTimeForStreamTime:previousCuepoint.endTime + 0.01]] }];
            return;
        }
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RCTVideo_progress" object:nil userInfo:@{@"progress": [NSNumber numberWithDouble: currentTimeSecs / duration]}];
    
    if( currentTimeSecs >= 0 && self.onVideoProgress) {
        
        float contentTime = currentTimeSecs;
        if (self->streamManager) {
            contentTime = [self->streamManager contentTimeForStreamTime: currentTimeSecs];
        }
        
        self.onVideoProgress(@{
            @"currentTime": [NSNumber numberWithFloat:contentTime],
            @"playableDuration": [self calculatePlayableDuration],
            @"atValue": [NSNumber numberWithLongLong:currentTime.value],
            @"atTimescale": [NSNumber numberWithInt:currentTime.timescale],
            @"target": self.reactTag,
            @"seekableDuration": [self calculateSeekableDuration],
                             });
    }
}

/*!
 * Calculates and returns the playable duration of the current player item using its loaded time ranges.
 *
 * \returns The playable duration of the current player item in seconds.
 */
- (NSNumber *)calculatePlayableDuration
{
    AVPlayerItem *video = _player.currentItem;
    if (video.status == AVPlayerItemStatusReadyToPlay) {
        __block CMTimeRange effectiveTimeRange;
        [video.loadedTimeRanges enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            CMTimeRange timeRange = [obj CMTimeRangeValue];
            if (CMTimeRangeContainsTime(timeRange, video.currentTime)) {
                effectiveTimeRange = timeRange;
                *stop = YES;
            }
        }];
        Float64 playableDuration = CMTimeGetSeconds(CMTimeRangeGetEnd(effectiveTimeRange));
        if (playableDuration > 0) {
            
            if (self->streamManager) {
                playableDuration = [self->streamManager contentTimeForStreamTime: playableDuration];
            }
            
            return [NSNumber numberWithFloat:playableDuration];
        }
    }
    return [NSNumber numberWithInteger:0];
}

- (NSNumber *)calculateSeekableDuration
{
    CMTimeRange timeRange = [self playerItemSeekableTimeRange];
    if (CMTIME_IS_NUMERIC(timeRange.duration))
    {
        Float64 contentDuration = CMTimeGetSeconds(timeRange.duration);
        
        if (self->streamManager) {
            contentDuration = [self->streamManager contentTimeForStreamTime: contentDuration];
        }
        
        return [NSNumber numberWithFloat:contentDuration];
    }
    return [NSNumber numberWithInteger:0];
}

- (void)addPlayerItemObservers
{
    [_playerItem addObserver:self forKeyPath:statusKeyPath options:0 context:nil];
    [_playerItem addObserver:self forKeyPath:playbackBufferEmptyKeyPath options:0 context:nil];
    [_playerItem addObserver:self forKeyPath:playbackLikelyToKeepUpKeyPath options:0 context:nil];
    [_playerItem addObserver:self forKeyPath:timedMetadata options:NSKeyValueObservingOptionNew context:nil];
    _playerItemObserversSet = YES;
}

/* Fixes https://github.com/brentvatne/react-native-video/issues/43
 * Crashes caused when trying to remove the observer when there is no
 * observer set */
- (void)removePlayerItemObservers
{
    if (_playerItemObserversSet) {
        [_playerItem removeObserver:self forKeyPath:statusKeyPath];
        [_playerItem removeObserver:self forKeyPath:playbackBufferEmptyKeyPath];
        [_playerItem removeObserver:self forKeyPath:playbackLikelyToKeepUpKeyPath];
        [_playerItem removeObserver:self forKeyPath:timedMetadata];
        _playerItemObserversSet = NO;
    }
}

#pragma mark - Player and source

- (void)setSrc:(NSDictionary *)source
{
    _source = source;
    [self removePlayerLayer];
    [self removePlayerTimeObserver];
    [self removePlayerItemObservers];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) 0), dispatch_get_main_queue(), ^{
        
        // perform on next run loop, otherwise other passed react-props may not be set
        [self playerItemForSource:self->_source withCallback:^(AVPlayerItem * playerItem) {
            [self setFilter:self->_filterName];
            [self setMaxBitRate:self->_maxBitRate];
            
            [self->_player pause];
            
            if (self->_playbackRateObserverRegistered) {
                [self->_player removeObserver:self forKeyPath:playbackRate context:nil];
                self->_playbackRateObserverRegistered = NO;
            }
            if (self->_isExternalPlaybackActiveObserverRegistered) {
                [self->_player removeObserver:self forKeyPath:externalPlaybackActive context:nil];
                self->_isExternalPlaybackActiveObserverRegistered = NO;
            }
            
            NSString *ads_ContentSourceID = [self->_source objectForKey:@"ads_ContentSourceID"];
            if (ads_ContentSourceID && !self->_disableAds) {
                self->_player = [[AVPlayer alloc] init];
                NSString *ads_VideoID = [self->_source objectForKey:@"ads_VideoID"];
                [self requestStream:ads_ContentSourceID kVideoID:ads_VideoID];
            }else{
                self->_playerItem = playerItem;
                [self addPlayerItemObservers];
                self->_player = [AVPlayer playerWithPlayerItem:self->_playerItem];
            }
            
            self->_player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
            
            [self->_player addObserver:self forKeyPath:playbackRate options:0 context:nil];
            self->_playbackRateObserverRegistered = YES;
            
            [self->_player addObserver:self forKeyPath:externalPlaybackActive options:0 context:nil];
            self->_isExternalPlaybackActiveObserverRegistered = YES;
            
            [self addPlayerTimeObserver];
            if (@available(iOS 10.0, *)) {
                [self setAutomaticallyWaitsToMinimizeStalling:self->_automaticallyWaitsToMinimizeStalling];
            }
            
            //Perform on next run loop, otherwise onVideoLoadStart is nil
            if (self.onVideoLoadStart) {
                id uri = [self->_source objectForKey:@"uri"];
                id type = [self->_source objectForKey:@"type"];
                self.onVideoLoadStart(@{@"src": @{
                                                @"uri": uri ? uri : [NSNull null],
                                                @"type": type ? type : [NSNull null],
                                                @"isNetwork": [NSNumber numberWithBool:(bool)[self->_source objectForKey:@"isNetwork"]]},
                                        @"drm": self->_drm ? self->_drm : [NSNull null],
                                        @"target": self.reactTag
                                      });
            }
            
            
            // check if this is the first chunk
            if(self->_shahidYouboraOptions != nil) {
                [self initYoubora];
            }
        }];
    });
    _videoLoadStarted = YES;
}

- (void) initYoubora {
    dispatch_async(dispatch_get_main_queue(), ^{
        YBOptions *ybOptions = [YBOptions new];
        //                    NSLog(@"==== set adapter");
        ybOptions.accountCode = [self->_shahidYouboraOptions objectForKey:@"accountCode"];;
        ybOptions.username = [self->_shahidYouboraOptions objectForKey:@"username"];
        ybOptions.contentTitle = [self->_shahidYouboraOptions objectForKey:@"title"];
        ybOptions.program = [self->_shahidYouboraOptions objectForKey:@"program"];
        ybOptions.contentTransactionCode = [self->_shahidYouboraOptions objectForKey:@"contentTransactionCode"];
        ybOptions.parseCdnNode = [self->_shahidYouboraOptions objectForKey:@"parseCdnNode"];
        ybOptions.enabled =  @YES ;
        ybOptions.contentIsLive = [self->_shahidYouboraOptions objectForKey:@"isLive"];
        ybOptions.contentDuration = [self->_shahidYouboraOptions objectForKey:@"contentDuration"];
        ybOptions.contentStreamingProtocol = [self->_shahidYouboraOptions objectForKey:@"contentStreamingProtocol"];
        ybOptions.contentResource = [self->_shahidYouboraOptions objectForKey:@"contentResource"];
        ybOptions.userType = [self->_shahidYouboraOptions objectForKey:@"userType"];
        ybOptions.contentMetadata = [self->_shahidYouboraOptions objectForKey:@"contentMetadata"];
        ybOptions.customDimension1 = [self->_shahidYouboraOptions objectForKey:@"extraparam.1"];
        ybOptions.customDimension2 = [self->_shahidYouboraOptions objectForKey:@"extraparam.2"];
        ybOptions.customDimension3 = [self->_shahidYouboraOptions objectForKey:@"extraparam.3"];
        ybOptions.customDimension4 = [self->_shahidYouboraOptions objectForKey:@"extraparam.4"];
        ybOptions.customDimension5 = [self->_shahidYouboraOptions objectForKey:@"extraparam.5"];
        ybOptions.customDimension6 = [self->_shahidYouboraOptions objectForKey:@"extraparam.6"];
        ybOptions.customDimension7 = [self->_shahidYouboraOptions objectForKey:@"extraparam.7"];
        
        //                    [YBLog setDebugLevel:YBLogLevelVerbose];
        [YBLog setDebugLevel:YBLogLevelError];
        self->_youboraPlugin = [[YBPlugin alloc] initWithOptions:ybOptions];
        self->_adapter = [[CustomAdapter alloc] initWithPlayer:self->_player];
        [self->_youboraPlugin setAdapter:self->_adapter];
        
        
        self->_adapter.customArguments = @{
            @"contentPlaybackType": [self->_shahidYouboraOptions objectForKey:@"contentPlaybackType"],
            @"contentSeason": [self->_shahidYouboraOptions objectForKey:@"season"],
            @"tvshow": [self->_shahidYouboraOptions objectForKey:@"tvShow"] ,
            @"contentId": [self->_shahidYouboraOptions objectForKey:@"contentId"],
            @"contentType": [self->_shahidYouboraOptions objectForKey:@"contentType"],
            @"drm":  [[self->_shahidYouboraOptions objectForKey:@"contentDrm"] isEqualToNumber: @1]  ? @"true" : @"false",
            @"contentGenre": [self->_shahidYouboraOptions objectForKey:@"contentGenre"],
            @"contentLanguage": [self->_shahidYouboraOptions objectForKey:@"contentLanguage"],
            @"rendition": [self->_shahidYouboraOptions objectForKey:@"rendition"],
            @"contentChannel":  [ self->_shahidYouboraOptions objectForKey:@"contentChannels" ],
        };
        
    });
}

- (void)setDrm:(NSDictionary *)drm {
    _drm = drm;
}

- (void)setShahidYouboraOptions:(NSDictionary *)youboraOptions {
    _shahidYouboraOptions = youboraOptions;
}

- (NSURL*) urlFilePath:(NSString*) filepath {
    if ([filepath containsString:@"file://"]) {
        return [NSURL URLWithString:filepath];
    }
    
    // if no file found, check if the file exists in the Document directory
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString* relativeFilePath = [filepath lastPathComponent];
    // the file may be multiple levels below the documents directory
    NSArray* fileComponents = [filepath componentsSeparatedByString:@"Documents/"];
    if (fileComponents.count > 1) {
        relativeFilePath = [fileComponents objectAtIndex:1];
    }
    
    NSString *path = [paths.firstObject stringByAppendingPathComponent:relativeFilePath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return [NSURL fileURLWithPath:path];
    }
    return nil;
}

- (void)playerItemPrepareText:(AVAsset *)asset assetOptions:(NSDictionary * __nullable)assetOptions withCallback:(void(^)(AVPlayerItem *))handler
{
    if (!_textTracks || _textTracks.count==0) {
        handler([AVPlayerItem playerItemWithAsset:asset]);
        return;
    }
    
    // AVPlayer can't airplay AVMutableCompositions
    _allowsExternalPlayback = NO;
    
    // sideload text tracks
    AVMutableComposition *mixComposition = [[AVMutableComposition alloc] init];
    
    AVAssetTrack *videoAsset = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVMutableCompositionTrack *videoCompTrack = [mixComposition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    [videoCompTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoAsset.timeRange.duration)
                            ofTrack:videoAsset
                             atTime:kCMTimeZero
                              error:nil];
    
    AVAssetTrack *audioAsset = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    AVMutableCompositionTrack *audioCompTrack = [mixComposition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
    [audioCompTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoAsset.timeRange.duration)
                            ofTrack:audioAsset
                             atTime:kCMTimeZero
                              error:nil];
    
    NSMutableArray* validTextTracks = [NSMutableArray array];
    for (int i = 0; i < _textTracks.count; ++i) {
        AVURLAsset *textURLAsset;
        NSString *textUri = [_textTracks objectAtIndex:i][@"uri"];
        if ([[textUri lowercaseString] hasPrefix:@"http"]) {
            textURLAsset = [AVURLAsset URLAssetWithURL:[NSURL URLWithString:textUri] options:assetOptions];
        } else {
            textURLAsset = [AVURLAsset URLAssetWithURL:[self urlFilePath:textUri] options:nil];
        }
        AVAssetTrack *textTrackAsset = [textURLAsset tracksWithMediaType:AVMediaTypeText].firstObject;
        if (!textTrackAsset) continue; // fix when there's no textTrackAsset
        [validTextTracks addObject:[_textTracks objectAtIndex:i]];
        AVMutableCompositionTrack *textCompTrack = [mixComposition
                                                    addMutableTrackWithMediaType:AVMediaTypeText
                                                    preferredTrackID:kCMPersistentTrackID_Invalid];
        [textCompTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, videoAsset.timeRange.duration)
                               ofTrack:textTrackAsset
                                atTime:kCMTimeZero
                                 error:nil];
    }
    if (validTextTracks.count != _textTracks.count) {
        [self setTextTracks:validTextTracks];
    }
    
    handler([AVPlayerItem playerItemWithAsset:mixComposition]);
}

- (void)playerItemForSource:(NSDictionary *)source withCallback:(void(^)(AVPlayerItem *))handler
{
    bool isNetwork = [RCTConvert BOOL:[source objectForKey:@"isNetwork"]];
    bool isAsset = [RCTConvert BOOL:[source objectForKey:@"isAsset"]];
    NSString *uri = [source objectForKey:@"uri"];
    NSString *type = [source objectForKey:@"type"];
    AVURLAsset *asset;
    if (!uri || [uri isEqualToString:@""]) {
        DebugLog(@"Could not find video URL in source '%@'", source);
        return;
    }
    
    NSURL *url = isNetwork || isAsset
    ? [NSURL URLWithString:uri]
    : [[NSURL alloc] initFileURLWithPath:[[NSBundle mainBundle] pathForResource:uri ofType:type]];
    NSMutableDictionary *assetOptions = [[NSMutableDictionary alloc] init];
    
    if (isNetwork) {
        /* Per #1091, this is not a public API.
         * We need to either get approval from Apple to use this  or use a different approach.
         NSDictionary *headers = [source objectForKey:@"requestHeaders"];
         if ([headers count] > 0) {
         [assetOptions setObject:headers forKey:@"AVURLAssetHTTPHeaderFieldsKey"];
         }
         */
        NSArray *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
        [assetOptions setObject:cookies forKey:AVURLAssetHTTPCookiesKey];
        
#if __has_include(<react-native-video/RCTVideoCache.h>)
        bool shouldCache = [RCTConvert BOOL:[source objectForKey:@"shouldCache"]];
        
        if (shouldCache && (!_textTracks || !_textTracks.count)) {
            /* The DVURLAsset created by cache doesn't have a tracksWithMediaType property, so trying
             * to bring in the text track code will crash. I suspect this is because the asset hasn't fully loaded.
             * Until this is fixed, we need to bypass caching when text tracks are specified.
             */
            DebugLog(@"Caching is not supported for uri '%@' because text tracks are not compatible with the cache. Checkout https://github.com/react-native-community/react-native-video/blob/master/docs/caching.md", uri);
            [self playerItemForSourceUsingCache:uri assetOptions:assetOptions withCallback:handler];
            return;
        }
#endif
        
        asset = [AVURLAsset URLAssetWithURL:url options:assetOptions];
    } else if (isAsset) {
        asset = [AVURLAsset URLAssetWithURL:url options:nil];
    } else {
        asset = [AVURLAsset URLAssetWithURL:[[NSURL alloc] initFileURLWithPath:[[NSBundle mainBundle] pathForResource:uri ofType:type]] options:nil];
    }
    // Reset _loadingRequest
    if (_loadingRequest != nil) {
        [_loadingRequest finishLoading];
    }
    _requestingCertificate = NO;
    _requestingCertificateErrored = NO;
    // End Reset _loadingRequest
    if (self->_drm != nil) {
        dispatch_queue_t queue = dispatch_queue_create("assetQueue", nil);
        [asset.resourceLoader setDelegate:self queue:queue];
    }
    
    [self playerItemPrepareText:asset assetOptions:assetOptions withCallback:handler];
}

#if __has_include(<react-native-video/RCTVideoCache.h>)

- (void)playerItemForSourceUsingCache:(NSString *)uri assetOptions:(NSDictionary *)options withCallback:(void(^)(AVPlayerItem *))handler {
    NSURL *url = [NSURL URLWithString:uri];
    [_videoCache getItemForUri:uri withCallback:^(RCTVideoCacheStatus videoCacheStatus, AVAsset * _Nullable cachedAsset) {
        switch (videoCacheStatus) {
            case RCTVideoCacheStatusMissingFileExtension: {
                DebugLog(@"Could not generate cache key for uri '%@'. It is currently not supported to cache urls that do not include a file extension. The video file will not be cached. Checkout https://github.com/react-native-community/react-native-video/blob/master/docs/caching.md", uri);
                AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:options];
                [self playerItemPrepareText:asset assetOptions:options withCallback:handler];
                return;
            }
            case RCTVideoCacheStatusUnsupportedFileExtension: {
                DebugLog(@"Could not generate cache key for uri '%@'. The file extension of that uri is currently not supported. The video file will not be cached. Checkout https://github.com/react-native-community/react-native-video/blob/master/docs/caching.md", uri);
                AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:options];
                [self playerItemPrepareText:asset assetOptions:options withCallback:handler];
                return;
            }
            default:
                if (cachedAsset) {
                    DebugLog(@"Playing back uri '%@' from cache", uri);
                    // See note in playerItemForSource about not being able to support text tracks & caching
                    handler([AVPlayerItem playerItemWithAsset:cachedAsset]);
                    return;
                }
        }
        
        DVURLAsset *asset = [[DVURLAsset alloc] initWithURL:url options:options networkTimeout:10000];
        asset.loaderDelegate = self;
        
        /* More granular code to have control over the DVURLAsset
         DVAssetLoaderDelegate *resourceLoaderDelegate = [[DVAssetLoaderDelegate alloc] initWithURL:url];
         resourceLoaderDelegate.delegate = self;
         NSURLComponents *components = [[NSURLComponents alloc] initWithURL:url resolvingAgainstBaseURL:NO];
         components.scheme = [DVAssetLoaderDelegate scheme];
         AVURLAsset *asset = [[AVURLAsset alloc] initWithURL:[components URL] options:options];
         [asset.resourceLoader setDelegate:resourceLoaderDelegate queue:dispatch_get_main_queue()];
         */
        
        handler([AVPlayerItem playerItemWithAsset:asset]);
    }];
}

#pragma mark - DVAssetLoaderDelegate

- (void)dvAssetLoaderDelegate:(DVAssetLoaderDelegate *)loaderDelegate
                  didLoadData:(NSData *)data
                       forURL:(NSURL *)url {
    [_videoCache storeItem:data forUri:[url absoluteString] withCallback:^(BOOL success) {
        DebugLog(@"Cache data stored successfully 🎉");
    }];
}

#endif

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (self->_playerItem == nil) {
        self->_playerItem = [self->_player currentItem];
        [self addPlayerItemObservers];
    }
    
    if([keyPath isEqualToString:readyForDisplayKeyPath] && [change objectForKey:NSKeyValueChangeNewKey] && self.onReadyForDisplay) {
        self.onReadyForDisplay(@{@"target": self.reactTag});
        return;
    }
    
    if (object == _playerItem) {
        // When timeMetadata is read the event onTimedMetadata is triggered
        if ([keyPath isEqualToString:timedMetadata]) {
            NSArray<AVMetadataItem *> *items = [change objectForKey:@"new"];
            if (items && ![items isEqual:[NSNull null]] && items.count > 0) {
                NSMutableArray *array = [NSMutableArray new];
                for (AVMetadataItem *item in items) {
                    NSString *value = (NSString *)item.value;
                    NSString *identifier = item.identifier;
                    
                    if (![value isEqual: [NSNull null]]) {
                        NSDictionary *dictionary = [[NSDictionary alloc] initWithObjects:@[value, identifier] forKeys:@[@"value", @"identifier"]];
                        
                        [array addObject:dictionary];
                    }
                }
                
                self.onTimedMetadata(@{
                    @"target": self.reactTag,
                    @"metadata": array
                                     });
            }
        }
        
        if ([keyPath isEqualToString:statusKeyPath]) {
            // Handle player item status change.
            if (_playerItem.status == AVPlayerItemStatusReadyToPlay) {
                float duration = CMTimeGetSeconds(_playerItem.asset.duration);
                
                if (isnan(duration)) {
                    duration = 0.0;
                }
                
                NSObject *width = @"undefined";
                NSObject *height = @"undefined";
                NSString *orientation = @"undefined";
                
                if ([_playerItem.asset tracksWithMediaType:AVMediaTypeVideo].count > 0) {
                    AVAssetTrack *videoTrack = [[_playerItem.asset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
                    width = [NSNumber numberWithFloat:videoTrack.naturalSize.width];
                    height = [NSNumber numberWithFloat:videoTrack.naturalSize.height];
                    CGAffineTransform preferredTransform = [videoTrack preferredTransform];
                    
                    if ((videoTrack.naturalSize.width == preferredTransform.tx
                         && videoTrack.naturalSize.height == preferredTransform.ty)
                        || (preferredTransform.tx == 0 && preferredTransform.ty == 0))
                    {
                        orientation = @"landscape";
                    } else {
                        orientation = @"portrait";
                    }
                }
                
                if (self.onVideoLoad && _videoLoadStarted) {
                    
                    float contentDuration = duration;
                    if (self->streamManager) {
                        contentDuration = [self->streamManager contentTimeForStreamTime: duration];
                    }
                    
                    self.onVideoLoad(@{@"duration": [NSNumber numberWithFloat:contentDuration],
                                       @"currentTime": [NSNumber numberWithFloat:CMTimeGetSeconds(_playerItem.currentTime)],
                                       @"canPlayReverse": [NSNumber numberWithBool:_playerItem.canPlayReverse],
                                       @"canPlayFastForward": [NSNumber numberWithBool:_playerItem.canPlayFastForward],
                                       @"canPlaySlowForward": [NSNumber numberWithBool:_playerItem.canPlaySlowForward],
                                       @"canPlaySlowReverse": [NSNumber numberWithBool:_playerItem.canPlaySlowReverse],
                                       @"canStepBackward": [NSNumber numberWithBool:_playerItem.canStepBackward],
                                       @"canStepForward": [NSNumber numberWithBool:_playerItem.canStepForward],
                                       @"naturalSize": @{
                                               @"width": width,
                                               @"height": height,
                                               @"orientation": orientation
                                       },
                                       @"audioTracks": [self getAudioTrackInfo],
                                       @"textTracks": [self getTextTrackInfo],
                                       @"target": self.reactTag});
                    
                    if (self.onAdEvent && self->_cuepoints) {
                        NSMutableArray *podTimes = [[NSMutableArray alloc] initWithCapacity:0];
                        
                        for (IMACuepoint *point in self->_cuepoints) {
                            [podTimes addObject:[NSNumber numberWithFloat: point.startTime/duration*100]];
                        }
                        
                        self.onAdEvent(@{
                            @"type": @"CuePointsChange",
                            @"data": @{@"cuePoints": podTimes}});
                    }
                }
                
                _videoLoadStarted = NO;
                
                [self attachListeners];
                [self applyModifiers];
            } else if (_playerItem.status == AVPlayerItemStatusFailed && self.onVideoError) {
                self.onVideoError(@{@"error": @{@"code": [NSNumber numberWithInteger: _playerItem.error.code],
                                                @"localizedDescription": [_playerItem.error localizedDescription] == nil ? @"" : [_playerItem.error localizedDescription],
                                                @"localizedFailureReason": [_playerItem.error localizedFailureReason] == nil ? @"" : [_playerItem.error localizedFailureReason],
                                                @"localizedRecoverySuggestion": [_playerItem.error localizedRecoverySuggestion] == nil ? @"" : [_playerItem.error localizedRecoverySuggestion],
                                                @"domain": _playerItem != nil && _playerItem.error != nil ? _playerItem.error.domain : @"RTCVideo"},
                                    @"target": self.reactTag});
            }
        } else if ([keyPath isEqualToString:playbackBufferEmptyKeyPath]) {
            _playerBufferEmpty = YES;
            self.onVideoBuffer(@{@"isBuffering": @(YES), @"target": self.reactTag});
        } else if ([keyPath isEqualToString:playbackLikelyToKeepUpKeyPath]) {
            // Continue playing (or not if paused) after being paused due to hitting an unbuffered zone.
            if ((!(_controls || _fullscreenPlayerPresented) || _playerBufferEmpty) && _playerItem.playbackLikelyToKeepUp) {
                [self setPaused:_paused];
            }
            _playerBufferEmpty = NO;
            self.onVideoBuffer(@{@"isBuffering": @(NO), @"target": self.reactTag});
        }
    } else if (object == _player) {
        if([keyPath isEqualToString:playbackRate]) {
            if(self.onPlaybackRateChange) {
                self.onPlaybackRateChange(@{@"playbackRate": [NSNumber numberWithFloat:_player.rate],
                                            @"target": self.reactTag});
            }
            if(_playbackStalled && _player.rate > 0) {
                if(self.onPlaybackResume) {
                    self.onPlaybackResume(@{@"playbackRate": [NSNumber numberWithFloat:_player.rate],
                                            @"target": self.reactTag});
                }
                _playbackStalled = NO;
            }
        }
        else if([keyPath isEqualToString:externalPlaybackActive]) {
            if(self.onVideoExternalPlaybackChange) {
                self.onVideoExternalPlaybackChange(@{@"isExternalPlaybackActive": [NSNumber numberWithBool:_player.isExternalPlaybackActive],
                                                     @"target": self.reactTag});
            }
        }
    } else if (object == _playerViewController.contentOverlayView) {
        // when controls==true, this is a hack to reset the rootview when rotation happens in fullscreen
        if ([keyPath isEqualToString:@"frame"]) {
            
            CGRect oldRect = [change[NSKeyValueChangeOldKey] CGRectValue];
            CGRect newRect = [change[NSKeyValueChangeNewKey] CGRectValue];
            
            if (!CGRectEqualToRect(oldRect, newRect)) {
                if (CGRectEqualToRect(newRect, [UIScreen mainScreen].bounds)) {
                    NSLog(@"in fullscreen");
                } else NSLog(@"not fullscreen");
                
                [self.reactViewController.view setFrame:[UIScreen mainScreen].bounds];
                [self.reactViewController.view setNeedsLayout];
            }
            
            return;
        }
    }
}

- (void)attachListeners
{
    // listen for end of file
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemDidPlayToEndTimeNotification
                                                  object:[_player currentItem]];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemDidReachEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:[_player currentItem]];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemPlaybackStalledNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playbackStalled:)
                                                 name:AVPlayerItemPlaybackStalledNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemNewAccessLogEntryNotification
                                                  object:nil];
    //    [[NSNotificationCenter defaultCenter] addObserver:self
    //                                             selector:@selector(handleAVPlayerAccess:)
    //                                                 name:AVPlayerItemNewAccessLogEntryNotification
    //                                               object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name: AVPlayerItemFailedToPlayToEndTimeNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didFailToFinishPlaying:)
                                                 name: AVPlayerItemFailedToPlayToEndTimeNotification
                                               object:nil];
    
}

//- (void)handleAVPlayerAccess:(NSNotification *)notification {
//    AVPlayerItemAccessLog *accessLog = [((AVPlayerItem *)notification.object) accessLog];
//    AVPlayerItemAccessLogEvent *lastEvent = accessLog.events.lastObject;
//
//    /* TODO: get this working
//     if (self.onBandwidthUpdate) {
//     self.onBandwidthUpdate(@{@"bitrate": [NSNumber numberWithFloat:lastEvent.observedBitrate]});
//     }
//     */
//}

- (void)didFailToFinishPlaying:(NSNotification *)notification {
    NSError *error = notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    self.onVideoError(@{@"error": @{@"code": [NSNumber numberWithInteger: error.code],
                                    @"localizedDescription": [error localizedDescription] == nil ? @"" : [error localizedDescription],
                                    @"localizedFailureReason": [error localizedFailureReason] == nil ? @"" : [error localizedFailureReason],
                                    @"localizedRecoverySuggestion": [error localizedRecoverySuggestion] == nil ? @"" : [error localizedRecoverySuggestion],
                                    @"domain": error.domain},
                        @"target": self.reactTag});
}

- (void)playbackStalled:(NSNotification *)notification
{
    if(self.onPlaybackStalled) {
        self.onPlaybackStalled(@{@"target": self.reactTag});
    }
    _playbackStalled = YES;
}

- (void)playerItemDidReachEnd:(NSNotification *)notification
{
    if(self.onVideoEnd) {
        self.onVideoEnd(@{@"target": self.reactTag});
    }
    
    if (_repeat) {
        AVPlayerItem *item = [notification object];
        [item seekToTime:kCMTimeZero];
        [self applyModifiers];
    } else {
        [self removePlayerTimeObserver];
    }
}

#pragma mark - Prop setters

- (void)setResizeMode:(NSString*)mode
{
    if( _controls )
    {
        _playerViewController.videoGravity = mode;
    }
    else
    {
        _playerLayer.videoGravity = mode;
    }
    _resizeMode = mode;
}

- (void)setPlayInBackground:(BOOL)playInBackground
{
    _playInBackground = playInBackground;
}

- (void)setAllowsExternalPlayback:(BOOL)allowsExternalPlayback
{
    _allowsExternalPlayback = allowsExternalPlayback;
    _player.allowsExternalPlayback = _allowsExternalPlayback;
}

- (void)setPlayWhenInactive:(BOOL)playWhenInactive
{
    _playWhenInactive = playWhenInactive;
}

- (void)setPictureInPicture:(BOOL)pictureInPicture
{
#if TARGET_OS_IOS
    if (_pictureInPicture == pictureInPicture) {
        return;
    }
    
    _pictureInPicture = pictureInPicture;
    if (_pipController && _pictureInPicture && ![_pipController isPictureInPictureActive]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [_pipController startPictureInPicture];
        });
    } else if (_pipController && !_pictureInPicture && [_pipController isPictureInPictureActive]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [_pipController stopPictureInPicture];
        });
    }
#endif
}

#if TARGET_OS_IOS
- (void)setRestoreUserInterfaceForPIPStopCompletionHandler:(BOOL)restore
{
    if (_restoreUserInterfaceForPIPStopCompletionHandler != NULL) {
        _restoreUserInterfaceForPIPStopCompletionHandler(restore);
        _restoreUserInterfaceForPIPStopCompletionHandler = NULL;
    }
}

- (void)setupPipController {
    if (!_pipController && _playerLayer && [AVPictureInPictureController isPictureInPictureSupported]) {
        // Create new controller passing reference to the AVPlayerLayer
        _pipController = [[AVPictureInPictureController alloc] initWithPlayerLayer:_playerLayer];
        _pipController.delegate = self;
    }
}
#endif

- (void)setIgnoreSilentSwitch:(NSString *)ignoreSilentSwitch
{
    _ignoreSilentSwitch = ignoreSilentSwitch;
    [self applyModifiers];
}

- (void)setPaused:(BOOL)paused
{
    if (paused) {
        [_player pause];
        [_player setRate:0.0];
    } else {
        if([_ignoreSilentSwitch isEqualToString:@"ignore"]) {
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
        } else if([_ignoreSilentSwitch isEqualToString:@"obey"]) {
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:nil];
        }
        
        if (@available(iOS 10.0, *) && !_automaticallyWaitsToMinimizeStalling) {
            [_player playImmediatelyAtRate:_rate];
        } else {
            [_player play];
            [_player setRate:_rate];
        }
        [_player setRate:_rate];
    }
    
    _paused = paused;
}

- (float)getCurrentTime
{
    return _playerItem != NULL ? CMTimeGetSeconds(_playerItem.currentTime) : 0;
}

- (void)setCurrentTime:(float)currentTime
{
    NSDictionary *info = @{
        @"time": [NSNumber numberWithFloat:currentTime],
        @"tolerance": [NSNumber numberWithInt:100]
    };
    [self setSeek:info];
}

- (void)setSeek:(NSDictionary *)info
{
    NSNumber *seekTime = info[@"time"];
    IMACuepoint *previousCuepoint;
    if (self->streamManager) {
        // Dai snapback implementation
        seekTime = [NSNumber numberWithFloat:[self->streamManager streamTimeForContentTime: seekTime.doubleValue]];
        previousCuepoint = [self->streamManager previousCuepointForStreamTime:seekTime.doubleValue];
        
        if (previousCuepoint && !previousCuepoint.played) {
            if (seekTime.doubleValue <= previousCuepoint.endTime) {
                self->snapbackTime = [NSNumber numberWithFloat:[self->streamManager contentTimeForStreamTime:previousCuepoint.endTime + 0.01]];
            }else{
                self->snapbackTime = [NSNumber numberWithFloat:[self->streamManager contentTimeForStreamTime:seekTime.doubleValue]];
            }
            seekTime = [NSNumber numberWithFloat: previousCuepoint.startTime];
        }
    }
    NSNumber *seekTolerance = info[@"tolerance"];
    
    int timeScale = 1000;
    
    AVPlayerItem *item = _player.currentItem;
    if (item.status == AVPlayerItemStatusUnknown && seekTime == 0) {
        // saffar todo : fix replay + google DAI
    }
    if (item && item.status == AVPlayerItemStatusReadyToPlay) {
        // TODO check loadedTimeRanges
        
        CMTime cmSeekTime = CMTimeMakeWithSeconds([seekTime floatValue], timeScale);
        CMTime current = item.currentTime;
        
        // TODO figure out a good tolerance level
        CMTime tolerance = CMTimeMake([seekTolerance floatValue], timeScale);
        if (previousCuepoint && !previousCuepoint.played) {
            tolerance = kCMTimeZero;
        }
        BOOL wasPaused = _paused;
        
        if (CMTimeCompare(current, cmSeekTime) != 0) {
            if (!wasPaused) [_player pause];
            [_player seekToTime:cmSeekTime toleranceBefore:tolerance toleranceAfter:tolerance completionHandler:^(BOOL finished) {
                if (!self->_timeObserver) {
                    [self addPlayerTimeObserver];
                }
                if (!wasPaused) {
                    [self setPaused:false];
                }
                if(self.onVideoSeek) {
                    self.onVideoSeek(@{@"currentTime": [NSNumber numberWithFloat:CMTimeGetSeconds(item.currentTime)],
                                       @"seekTime": seekTime,
                                       @"target": self.reactTag});
                }
            }];
            
            _pendingSeek = false;
        }
        
    } else {
        // TODO: See if this makes sense and if so, actually implement it
        _pendingSeek = true;
        _pendingSeekTime = [seekTime floatValue];
    }
}

- (void)setRate:(float)rate
{
    _rate = rate;
    [self applyModifiers];
}

- (void)setMuted:(BOOL)muted
{
    _muted = muted;
    [self applyModifiers];
}

- (void)setVolume:(float)volume
{
    _volume = volume;
    [self applyModifiers];
}

- (void)setMaxBitRate:(float) maxBitRate {
    _maxBitRate = maxBitRate;
    _playerItem.preferredPeakBitRate = maxBitRate;
}

- (void)setAutomaticallyWaitsToMinimizeStalling:(BOOL)waits
{
    _automaticallyWaitsToMinimizeStalling = waits;
    if (@available(tvOS 10.0, *)) {
        _player.automaticallyWaitsToMinimizeStalling = waits;
    }
}


- (void)applyModifiers
{
    if (_muted) {
        if (!_controls) {
            [_player setVolume:0];
        }
        [_player setMuted:YES];
    } else {
        [_player setVolume:_volume];
        [_player setMuted:NO];
    }
    
    [self setMaxBitRate:_maxBitRate];
    [self setSelectedAudioTrack:_selectedAudioTrack];
    [self setSelectedTextTrack:_selectedTextTrack];
    [self setResizeMode:_resizeMode];
    [self setRepeat:_repeat];
    [self setPaused:_paused];
    [self setControls:_controls];
    [self setAllowsExternalPlayback:_allowsExternalPlayback];
}

- (void)setRepeat:(BOOL)repeat {
    _repeat = repeat;
}

- (void)setMediaSelectionTrackForCharacteristic:(AVMediaCharacteristic)characteristic
                                   withCriteria:(NSDictionary *)criteria
{
    NSString *type = criteria[@"type"];
    AVMediaSelectionGroup *group = [_player.currentItem.asset
                                    mediaSelectionGroupForMediaCharacteristic:characteristic];
    AVMediaSelectionOption *mediaOption;
    
    if ([type isEqualToString:@"disabled"]) {
        // Do nothing. We want to ensure option is nil
    } else if ([type isEqualToString:@"language"] || [type isEqualToString:@"title"]) {
        NSString *value = criteria[@"value"];
        for (int i = 0; i < group.options.count; ++i) {
            AVMediaSelectionOption *currentOption = [group.options objectAtIndex:i];
            NSString *optionValue;
            if ([type isEqualToString:@"language"]) {
                optionValue = [currentOption extendedLanguageTag];
            } else {
                optionValue = [[[currentOption commonMetadata]
                                valueForKey:@"value"]
                               objectAtIndex:0];
            }
            if ([value isEqualToString:optionValue]) {
                mediaOption = currentOption;
                break;
            }
        }
        //} else if ([type isEqualToString:@"default"]) {
        //  option = group.defaultOption; */
    } else if ([type isEqualToString:@"index"]) {
        if ([criteria[@"value"] isKindOfClass:[NSNumber class]]) {
            int index = [criteria[@"value"] intValue];
            if (group.options.count > index) {
                mediaOption = [group.options objectAtIndex:index];
            }
        }
    } else { // default. invalid type or "system"
        [_player.currentItem selectMediaOptionAutomaticallyInMediaSelectionGroup:group];
        return;
    }
    
    // If a match isn't found, option will be nil and text tracks will be disabled
    [_player.currentItem selectMediaOption:mediaOption inMediaSelectionGroup:group];
}

- (void)setSelectedAudioTrack:(NSDictionary *)selectedAudioTrack {
    _selectedAudioTrack = selectedAudioTrack;
    [self setMediaSelectionTrackForCharacteristic:AVMediaCharacteristicAudible
                                     withCriteria:_selectedAudioTrack];
}

- (void)setSelectedTextTrack:(NSDictionary *)selectedTextTrack {
    _selectedTextTrack = selectedTextTrack;
    if (_textTracks) { // sideloaded text tracks
        [self setSideloadedText];
    } else { // text tracks included in the HLS playlist
        [self setMediaSelectionTrackForCharacteristic:AVMediaCharacteristicLegible
                                         withCriteria:_selectedTextTrack];
    }
}

- (void) setSideloadedText {
    NSString *type = _selectedTextTrack[@"type"];
    NSArray *textTracks = [self getTextTrackInfo];
    
    // The first few tracks will be audio & video track
    int firstTextIndex = 0;
    for (firstTextIndex = 0; firstTextIndex < _player.currentItem.tracks.count; ++firstTextIndex) {
        if ([_player.currentItem.tracks[firstTextIndex].assetTrack hasMediaCharacteristic:AVMediaCharacteristicLegible]) {
            break;
        }
    }
    
    int selectedTrackIndex = RCTVideoUnset;
    
    if ([type isEqualToString:@"disabled"]) {
        // Do nothing. We want to ensure option is nil
    } else if ([type isEqualToString:@"language"]) {
        NSString *selectedValue = _selectedTextTrack[@"value"];
        for (int i = 0; i < textTracks.count; ++i) {
            NSDictionary *currentTextTrack = [textTracks objectAtIndex:i];
            if ([selectedValue isEqualToString:currentTextTrack[@"language"]]) {
                selectedTrackIndex = i;
                break;
            }
        }
    } else if ([type isEqualToString:@"title"]) {
        NSString *selectedValue = _selectedTextTrack[@"value"];
        for (int i = 0; i < textTracks.count; ++i) {
            NSDictionary *currentTextTrack = [textTracks objectAtIndex:i];
            if ([selectedValue isEqualToString:currentTextTrack[@"title"]]) {
                selectedTrackIndex = i;
                break;
            }
        }
    } else if ([type isEqualToString:@"index"]) {
        if ([_selectedTextTrack[@"value"] isKindOfClass:[NSNumber class]]) {
            int index = [_selectedTextTrack[@"value"] intValue];
            if (textTracks.count > index) {
                selectedTrackIndex = index;
            }
        }
    }
    
    // in the situation that a selected text track is not available (eg. specifies a textTrack not available)
    if (![type isEqualToString:@"disabled"] && selectedTrackIndex == RCTVideoUnset) {
        CFArrayRef captioningMediaCharacteristics = MACaptionAppearanceCopyPreferredCaptioningMediaCharacteristics(kMACaptionAppearanceDomainUser);
        NSArray *captionSettings = (__bridge NSArray*)captioningMediaCharacteristics;
        if ([captionSettings containsObject:AVMediaCharacteristicTranscribesSpokenDialogForAccessibility]) {
            selectedTrackIndex = 0; // If we can't find a match, use the first available track
            NSString *systemLanguage = [[NSLocale preferredLanguages] firstObject];
            for (int i = 0; i < textTracks.count; ++i) {
                NSDictionary *currentTextTrack = [textTracks objectAtIndex:i];
                if ([systemLanguage isEqualToString:currentTextTrack[@"language"]]) {
                    selectedTrackIndex = i;
                    break;
                }
            }
        }
    }
    
    for (int i = firstTextIndex; i < _player.currentItem.tracks.count; ++i) {
        BOOL isEnabled = NO;
        if (selectedTrackIndex != RCTVideoUnset) {
            isEnabled = i == selectedTrackIndex + firstTextIndex;
        }
        [_player.currentItem.tracks[i] setEnabled:isEnabled];
    }
}

-(void) setStreamingText {
    NSString *type = _selectedTextTrack[@"type"];
    AVMediaSelectionGroup *group = [_player.currentItem.asset
                                    mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicLegible];
    AVMediaSelectionOption *mediaOption;
    
    if ([type isEqualToString:@"disabled"]) {
        // Do nothing. We want to ensure option is nil
    } else if ([type isEqualToString:@"language"] || [type isEqualToString:@"title"]) {
        NSString *value = _selectedTextTrack[@"value"];
        for (int i = 0; i < group.options.count; ++i) {
            AVMediaSelectionOption *currentOption = [group.options objectAtIndex:i];
            NSString *optionValue;
            if ([type isEqualToString:@"language"]) {
                optionValue = [currentOption extendedLanguageTag];
            } else {
                optionValue = [[[currentOption commonMetadata]
                                valueForKey:@"value"]
                               objectAtIndex:0];
            }
            if ([value isEqualToString:optionValue]) {
                mediaOption = currentOption;
                break;
            }
        }
        //} else if ([type isEqualToString:@"default"]) {
        //  option = group.defaultOption; */
    } else if ([type isEqualToString:@"index"]) {
        if ([_selectedTextTrack[@"value"] isKindOfClass:[NSNumber class]]) {
            int index = [_selectedTextTrack[@"value"] intValue];
            if (group.options.count > index) {
                mediaOption = [group.options objectAtIndex:index];
            }
        }
    } else { // default. invalid type or "system"
        [_player.currentItem selectMediaOptionAutomaticallyInMediaSelectionGroup:group];
        return;
    }
    
    // If a match isn't found, option will be nil and text tracks will be disabled
    [_player.currentItem selectMediaOption:mediaOption inMediaSelectionGroup:group];
}

- (void)setTextTracks:(NSArray*) textTracks;
{
    _textTracks = textTracks;
    
    // in case textTracks was set after selectedTextTrack
    if (_selectedTextTrack) [self setSelectedTextTrack:_selectedTextTrack];
}

- (NSArray *)getAudioTrackInfo
{
    NSMutableArray *audioTracks = [[NSMutableArray alloc] init];
    AVMediaSelectionGroup *group = [_player.currentItem.asset
                                    mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicAudible];
    for (int i = 0; i < group.options.count; ++i) {
        AVMediaSelectionOption *currentOption = [group.options objectAtIndex:i];
        NSString *title = @"";
        NSArray *values = [[currentOption commonMetadata] valueForKey:@"value"];
        if (values.count > 0) {
            title = [values objectAtIndex:0];
        }
        NSString *language = [currentOption extendedLanguageTag] ? [currentOption extendedLanguageTag] : @"";
        NSDictionary *audioTrack = @{
            @"index": [NSNumber numberWithInt:i],
            @"title": title,
            @"language": language
        };
        [audioTracks addObject:audioTrack];
    }
    return audioTracks;
}

- (NSArray *)getTextTrackInfo
{
    // if sideloaded, textTracks will already be set
    if (_textTracks) return _textTracks;
    
    // if streaming video, we extract the text tracks
    NSMutableArray *textTracks = [[NSMutableArray alloc] init];
    AVMediaSelectionGroup *group = [_player.currentItem.asset
                                    mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicLegible];
    for (int i = 0; i < group.options.count; ++i) {
        AVMediaSelectionOption *currentOption = [group.options objectAtIndex:i];
        NSString *title = @"";
        NSArray *values = [[currentOption commonMetadata] valueForKey:@"value"];
        if (values.count > 0) {
            title = [values objectAtIndex:0];
        }
        NSString *language = [currentOption extendedLanguageTag] ? [currentOption extendedLanguageTag] : @"";
        NSDictionary *textTrack = @{
            @"index": [NSNumber numberWithInt:i],
            @"title": title,
            @"language": language
        };
        [textTracks addObject:textTrack];
    }
    return textTracks;
}

- (BOOL)getFullscreen
{
    return _fullscreenPlayerPresented;
}

- (void)setFullscreen:(BOOL) fullscreen {
    if( fullscreen && !_fullscreenPlayerPresented && _player )
    {
        // Ensure player view controller is not null
        if( !_playerViewController )
        {
            [self usePlayerViewController];
        }
        // Set presentation style to fullscreen
        [_playerViewController setModalPresentationStyle:UIModalPresentationFullScreen];
        
        // Find the nearest view controller
        UIViewController *viewController = [self firstAvailableUIViewController];
        if( !viewController )
        {
            UIWindow *keyWindow = [[UIApplication sharedApplication] keyWindow];
            viewController = keyWindow.rootViewController;
            if( viewController.childViewControllers.count > 0 )
            {
                viewController = viewController.childViewControllers.lastObject;
            }
        }
        if( viewController )
        {
            _presentingViewController = viewController;
            if(self.onVideoFullscreenPlayerWillPresent) {
                self.onVideoFullscreenPlayerWillPresent(@{@"target": self.reactTag});
            }
            [viewController presentViewController:_playerViewController animated:true completion:^{
                self->_playerViewController.showsPlaybackControls = YES;
                self->_fullscreenPlayerPresented = fullscreen;
                self->            _playerViewController.autorotate = self->_fullscreenAutorotate;
                if(self.onVideoFullscreenPlayerDidPresent) {
                    self.onVideoFullscreenPlayerDidPresent(@{@"target": self.reactTag});
                }
            }];
        }
    }
    else if ( !fullscreen && _fullscreenPlayerPresented )
    {
        [self videoPlayerViewControllerWillDismiss:_playerViewController];
        [_presentingViewController dismissViewControllerAnimated:true completion:^{
            [self videoPlayerViewControllerDidDismiss:self->_playerViewController];
        }];
    }
}

- (void)setFullscreenAutorotate:(BOOL)autorotate {
    _fullscreenAutorotate = autorotate;
    if (_fullscreenPlayerPresented) {
        _playerViewController.autorotate = autorotate;
    }
}

- (void)setFullscreenOrientation:(NSString *)orientation {
    _fullscreenOrientation = orientation;
    if (_fullscreenPlayerPresented) {
        _playerViewController.preferredOrientation = orientation;
    }
}

- (void)usePlayerViewController
{
    if( _player )
    {
        if (!_playerViewController) {
            _playerViewController = [self createPlayerViewController:_player withPlayerItem:_playerItem];
        }
        
        // to prevent video from being animated when resizeMode is 'cover'
        // resize mode must be set before subview is added
        [self setResizeMode:_resizeMode];
        
        if (_controls) {
            UIViewController *viewController = [self reactViewController];
            [viewController addChildViewController:_playerViewController];
            [self addSubview:_playerViewController.view];
        }
        
        [_playerViewController addObserver:self forKeyPath:readyForDisplayKeyPath options:NSKeyValueObservingOptionNew context:nil];
        
        [_playerViewController.contentOverlayView addObserver:self forKeyPath:@"frame" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:NULL];
    }
}

- (void)usePlayerLayer
{
    if( _player )
    {
        _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
        _playerLayer.frame = self.bounds;
        _playerLayer.needsDisplayOnBoundsChange = YES;
        
        // to prevent video from being animated when resizeMode is 'cover'
        // resize mode must be set before layer is added
        [self setResizeMode:_resizeMode];
        [_playerLayer addObserver:self forKeyPath:readyForDisplayKeyPath options:NSKeyValueObservingOptionNew context:nil];
        _playerLayerObserverSet = YES;
        
        [self.layer addSublayer:_playerLayer];
        self.layer.needsDisplayOnBoundsChange = YES;
#if TARGET_OS_IOS
        [self setupPipController];
#endif
    }
}

- (void)setControls:(BOOL)controls
{
    if( _controls != controls || (!_playerLayer && !_playerViewController) )
    {
        _controls = controls;
        if( _controls )
        {
            [self removePlayerLayer];
            [self usePlayerViewController];
        }
        else
        {
            [_playerViewController.view removeFromSuperview];
            _playerViewController = nil;
            [self usePlayerLayer];
        }
    }
}

- (void)setProgressUpdateInterval:(float)progressUpdateInterval
{
    _progressUpdateInterval = progressUpdateInterval;
    
    if (_timeObserver) {
        [self removePlayerTimeObserver];
        [self addPlayerTimeObserver];
    }
}

- (void)removePlayerLayer
{
    if (_loadingRequest != nil) {
        [_loadingRequest finishLoading];
    }
    _requestingCertificate = NO;
    _requestingCertificateErrored = NO;
    [_playerLayer removeFromSuperlayer];
    if (_playerLayerObserverSet) {
        [_playerLayer removeObserver:self forKeyPath:readyForDisplayKeyPath];
        _playerLayerObserverSet = NO;
    }
    _playerLayer = nil;
}

#pragma mark - RCTVideoPlayerViewControllerDelegate

- (void)videoPlayerViewControllerWillDismiss:(AVPlayerViewController *)playerViewController
{
    if (_playerViewController == playerViewController && _fullscreenPlayerPresented && self.onVideoFullscreenPlayerWillDismiss)
    {
        self.onVideoFullscreenPlayerWillDismiss(@{@"target": self.reactTag});
    }
}

- (void)videoPlayerViewControllerDidDismiss:(AVPlayerViewController *)playerViewController
{
    if (_playerViewController == playerViewController && _fullscreenPlayerPresented)
    {
        _fullscreenPlayerPresented = false;
        _presentingViewController = nil;
        _playerViewController = nil;
        [self applyModifiers];
        if(self.onVideoFullscreenPlayerDidDismiss) {
            self.onVideoFullscreenPlayerDidDismiss(@{@"target": self.reactTag});
        }
    }
}

- (void)setFilter:(NSString *)filterName {
    _filterName = filterName;
    
    if (!_filterEnabled) {
        return;
    } else if ([[_source objectForKey:@"uri"] rangeOfString:@"m3u8"].location != NSNotFound) {
        return; // filters don't work for HLS... return
    } else if (!_playerItem.asset) {
        return;
    }
    
    CIFilter *filter = [CIFilter filterWithName:filterName];
    _playerItem.videoComposition = [AVVideoComposition
                                    videoCompositionWithAsset:_playerItem.asset
                                    applyingCIFiltersWithHandler:^(AVAsynchronousCIImageFilteringRequest *_Nonnull request) {
        if (filter == nil) {
            [request finishWithImage:request.sourceImage context:nil];
        } else {
            CIImage *image = request.sourceImage.imageByClampingToExtent;
            [filter setValue:image forKey:kCIInputImageKey];
            CIImage *output = [filter.outputImage imageByCroppingToRect:request.sourceImage.extent];
            [request finishWithImage:output context:nil];
        }
    }];
}

- (void)setFilterEnabled:(BOOL)filterEnabled {
    _filterEnabled = filterEnabled;
}

#pragma mark - React View Management

- (void)insertReactSubview:(UIView *)view atIndex:(NSInteger)atIndex
{
    // We are early in the game and somebody wants to set a subview.
    // That can only be in the context of playerViewController.
    if( !_controls && !_playerLayer && !_playerViewController )
    {
        [self setControls:true];
    }
    
    if( _controls )
    {
        view.frame = self.bounds;
        [_playerViewController.contentOverlayView insertSubview:view atIndex:atIndex];
    }
    else
    {
        RCTLogError(@"video cannot have any subviews");
    }
    return;
}

- (void)removeReactSubview:(UIView *)subview
{
    if( _controls )
    {
        [subview removeFromSuperview];
    }
    else
    {
        RCTLogError(@"video cannot have any subviews");
    }
    return;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    if( _controls )
    {
        _playerViewController.view.frame = self.bounds;
        
        // also adjust all subviews of contentOverlayView
        for (UIView* subview in _playerViewController.contentOverlayView.subviews) {
            subview.frame = self.bounds;
        }
    }
    else
    {
        [CATransaction begin];
        [CATransaction setAnimationDuration:0];
        _playerLayer.frame = self.bounds;
        [CATransaction commit];
    }
}

#pragma mark - Lifecycle

- (void)removeFromSuperview
{
    [_player pause];
    if (_playbackRateObserverRegistered) {
        [_player removeObserver:self forKeyPath:playbackRate context:nil];
        _playbackRateObserverRegistered = NO;
    }
    if (_isExternalPlaybackActiveObserverRegistered) {
        [_player removeObserver:self forKeyPath:externalPlaybackActive context:nil];
        _isExternalPlaybackActiveObserverRegistered = NO;
    }
    _player = nil;
    
    [self removePlayerLayer];
    
    [_playerViewController.contentOverlayView removeObserver:self forKeyPath:@"frame"];
    [_playerViewController removeObserver:self forKeyPath:readyForDisplayKeyPath];
    [_playerViewController.view removeFromSuperview];
    _playerViewController.rctDelegate = nil;
    _playerViewController.player = nil;
    _playerViewController = nil;
    
    [self removePlayerTimeObserver];
    [self removePlayerItemObservers];
    
    _eventDispatcher = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [super removeFromSuperview];
}

#pragma mark - Export

- (void)save:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    
    AVAsset *asset = _playerItem.asset;
    
    if (asset != nil) {
        
        AVAssetExportSession *exportSession = [AVAssetExportSession
                                               exportSessionWithAsset:asset presetName:AVAssetExportPresetHighestQuality];
        
        if (exportSession != nil) {
            NSString *path = nil;
            //            NSArray *array = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
            path = [self generatePathInDirectory:[[self cacheDirectoryPath] stringByAppendingPathComponent:@"Videos"]
                                   withExtension:@".mp4"];
            NSURL *url = [NSURL fileURLWithPath:path];
            exportSession.outputFileType = AVFileTypeMPEG4;
            exportSession.outputURL = url;
            exportSession.videoComposition = _playerItem.videoComposition;
            exportSession.shouldOptimizeForNetworkUse = true;
            [exportSession exportAsynchronouslyWithCompletionHandler:^{
                
                switch ([exportSession status]) {
                    case AVAssetExportSessionStatusFailed:
                        reject(@"ERROR_COULD_NOT_EXPORT_VIDEO", @"Could not export video", exportSession.error);
                        break;
                    case AVAssetExportSessionStatusCancelled:
                        reject(@"ERROR_EXPORT_SESSION_CANCELLED", @"Export session was cancelled", exportSession.error);
                        break;
                    default:
                        resolve(@{@"uri": url.absoluteString});
                        break;
                }
                
            }];
            
        } else {
            
            reject(@"ERROR_COULD_NOT_CREATE_EXPORT_SESSION", @"Could not create export session", nil);
            
        }
        
    } else {
        
        reject(@"ERROR_ASSET_NIL", @"Asset is nil", nil);
        
    }
}

- (void)setLicenseResult:(NSString *)license {
    NSData *respondData = [self base64DataFromBase64String:license];
    NSLog(@"==== respond data %@", license);
    if (_loadingRequest != nil && respondData != nil) {
        AVAssetResourceLoadingDataRequest *dataRequest = [_loadingRequest dataRequest];
        [dataRequest respondWithData:respondData];
        [_loadingRequest finishLoading];
    } else {
        [self setLicenseResultError:@"No data from JS license response"];
    }
}

- (BOOL)setLicenseResultError:(NSString *)error {
    if (_loadingRequest != nil) {
        NSError *licenseError = [NSError errorWithDomain: @"RCTVideo"
                                                    code: RCTVideoErrorFromJSPart
                                                userInfo: @{
                                                    NSLocalizedDescriptionKey: error,
                                                    NSLocalizedFailureReasonErrorKey: error,
                                                    NSLocalizedRecoverySuggestionErrorKey: error
                                                }
                                 ];
        [self finishLoadingWithError:licenseError];
    }
    return NO;
}

- (BOOL)finishLoadingWithError:(NSError *)error {
    if (_loadingRequest && error != nil) {
        NSError *licenseError = error;
        [_loadingRequest finishLoadingWithError:licenseError];
        if (self.onVideoError) {
            self.onVideoError(@{@"error": @{@"code": [NSNumber numberWithInteger: error.code],
                                            @"localizedDescription": [error localizedDescription] == nil ? @"" : [error localizedDescription],
                                            @"localizedFailureReason": [error localizedFailureReason] == nil ? @"" : [error localizedFailureReason],
                                            @"localizedRecoverySuggestion": [error localizedRecoverySuggestion] == nil ? @"" : [error localizedRecoverySuggestion],
                                            @"domain": _playerItem.error == nil ? @"RCTVideo" : _playerItem.error.domain},
                                @"target": self.reactTag});
        }
    }
    return NO;
}

- (BOOL)ensureDirExistsWithPath:(NSString *)path {
    BOOL isDir = NO;
    NSError *error;
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
    if (!(exists && isDir)) {
        [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            return NO;
        }
    }
    return YES;
}

- (NSString *)generatePathInDirectory:(NSString *)directory withExtension:(NSString *)extension {
    NSString *fileName = [[[NSUUID UUID] UUIDString] stringByAppendingString:extension];
    [self ensureDirExistsWithPath:directory];
    return [directory stringByAppendingPathComponent:fileName];
}

- (NSString *)cacheDirectoryPath {
    NSArray *array = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return array[0];
}

#pragma mark - AVAssetResourceLoaderDelegate

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForRenewalOfRequestedResource:(AVAssetResourceRenewalRequest *)renewalRequest {
    return [self loadingRequestHandling:renewalRequest];
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
    return [self loadingRequestHandling:loadingRequest];
}

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSLog(@"didCancelLoadingRequest");
}

- (BOOL)loadingRequestHandling:(AVAssetResourceLoadingRequest *)loadingRequest {
    if (self->_requestingCertificate) {
        return YES;
    } else if (self->_requestingCertificateErrored) {
        return NO;
    }
    _loadingRequest = loadingRequest;
    NSURL *url = loadingRequest.request.URL;
    NSString *assetId = url.host;
    if (self->_drm != nil) {
        NSString *assetIdOverride = (NSString *)[self->_drm objectForKey:@"assetId"];
        if (assetIdOverride != nil) {
            assetId = assetIdOverride;
        }
        NSString *drmType = (NSString *)[self->_drm objectForKey:@"type"];
        if ([drmType isEqualToString:@"fairplay"]) {
            NSString *certificateStringUrl = (NSString *)[self->_drm objectForKey:@"certificateUrl"];
            if (certificateStringUrl != nil) {
                NSURL *certificateURL = [NSURL URLWithString:[certificateStringUrl stringByAddingPercentEscapesUsingEncoding:NSDataBase64DecodingIgnoreUnknownCharacters]];
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    // NSData *certificateData = [NSData dataWithContentsOfURL:certificateURL];
                    // if ([self->_drm objectForKey:@"base64Certificate"]) {
                    //   certificateData = [[NSData alloc] initWithBase64EncodedData:certificateData options:NSDataBase64DecodingIgnoreUnknownCharacters];
                    // }
                    NSURLResponse *response = nil;
                    NSError *error = nil;
                    NSData *certificateData = [NSURLConnection sendSynchronousRequest:[NSURLRequest requestWithURL:certificateURL] returningResponse:&response error:&error];
                    
                    if (certificateData != nil) {
                        NSData *assetIDData = [assetId dataUsingEncoding:NSDataBase64DecodingIgnoreUnknownCharacters];
                        AVAssetResourceLoadingDataRequest *dataRequest = [loadingRequest dataRequest];
                        
                        if (dataRequest != nil) {
                            NSError *spcError = nil;
                            
                            NSData *spcData = [self->_loadingRequest streamingContentKeyRequestDataForApp:certificateData contentIdentifier:assetIDData options:nil error:&spcError];
                            
                            // Request CKC to the server
                            NSString *licenseServer = (NSString *)[self->_drm objectForKey:@"licenseServer"];
                            if (spcError != nil) {
                                [self finishLoadingWithError:spcError];
                                self->_requestingCertificateErrored = YES;
                            }
                            if (spcData != nil) {
                                if(self.onGetLicense) {
                                    NSString *spcStr = [spcData base64EncodedStringWithOptions:0];
                                    self->_requestingCertificate = YES;
                                    self.onGetLicense(@{@"spc": spcStr,
                                                        @"target": self.reactTag});
                                } else if(licenseServer != nil) {
                                    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] init];
                                    [request setHTTPMethod:@"POST"];
                                    [request setURL:[NSURL URLWithString:licenseServer]];
                                    // HEADERS
                                    NSDictionary *headers = (NSDictionary *)[self->_drm objectForKey:@"headers"];
                                    if (headers != nil) {
                                        for (NSString *key in headers) {
                                            NSString *value = headers[key];
                                            [request setValue:value forHTTPHeaderField:key];
                                        }
                                    }
                                    //
                                    
                                    [request setHTTPBody: spcData];
                                    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
                                    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
                                    NSURLSessionDataTask *postDataTask = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *) response;
                                        if (error != nil) {
                                            NSLog(@"Error getting license from %@, HTTP status code %li", url, (long)[httpResponse statusCode]);
                                            [self finishLoadingWithError:error];
                                            self->_requestingCertificateErrored = YES;
                                        } else {
                                            if([httpResponse statusCode] != 200){
                                                NSLog(@"Error getting license from %@, HTTP status code %li", url, (long)[httpResponse statusCode]);
                                                NSError *licenseError = [NSError errorWithDomain: @"RCTVideo"
                                                                                            code: RCTVideoErrorLicenseRequestNotOk
                                                                                        userInfo: @{
                                                                                            NSLocalizedDescriptionKey: @"Error obtaining license.",
                                                                                            NSLocalizedFailureReasonErrorKey: [NSString stringWithFormat:@"License server responded with status code %li", (long)[httpResponse statusCode]],
                                                                                            NSLocalizedRecoverySuggestionErrorKey: @"Did you send the correct data to the license Server? Is the server ok?"
                                                                                        }
                                                                         ];
                                                [self finishLoadingWithError:licenseError];
                                                self->_requestingCertificateErrored = YES;
                                            } else if (data != nil) {
                                                [dataRequest respondWithData:data];
                                                [loadingRequest finishLoading];
                                            } else {
                                                NSError *licenseError = [NSError errorWithDomain: @"RCTVideo"
                                                                                            code: RCTVideoErrorNoDataFromLicenseRequest
                                                                                        userInfo: @{
                                                                                            NSLocalizedDescriptionKey: @"Error obtaining DRM license.",
                                                                                            NSLocalizedFailureReasonErrorKey: @"No data received from the license server.",
                                                                                            NSLocalizedRecoverySuggestionErrorKey: @"Is the licenseServer ok?."
                                                                                        }
                                                                         ];
                                                [self finishLoadingWithError:licenseError];
                                                self->_requestingCertificateErrored = YES;
                                            }
                                            
                                        }
                                    }];
                                    [postDataTask resume];
                                }
                                
                            } else {
                                NSError *licenseError = [NSError errorWithDomain: @"RCTVideo"
                                                                            code: RCTVideoErrorNoSPC
                                                                        userInfo: @{
                                                                            NSLocalizedDescriptionKey: @"Error obtaining license.",
                                                                            NSLocalizedFailureReasonErrorKey: @"No spc received.",
                                                                            NSLocalizedRecoverySuggestionErrorKey: @"Check your DRM config."
                                                                        }
                                                         ];
                                [self finishLoadingWithError:licenseError];
                                self->_requestingCertificateErrored = YES;
                            }
                            
                        } else {
                            NSError *licenseError = [NSError errorWithDomain: @"RCTVideo"
                                                                        code: RCTVideoErrorNoDataRequest
                                                                    userInfo: @{
                                                                        NSLocalizedDescriptionKey: @"Error obtaining DRM license.",
                                                                        NSLocalizedFailureReasonErrorKey: @"No dataRequest found.",
                                                                        NSLocalizedRecoverySuggestionErrorKey: @"Check your DRM configuration."
                                                                    }
                                                     ];
                            [self finishLoadingWithError:licenseError];
                            self->_requestingCertificateErrored = YES;
                        }
                    } else {
                        NSError *licenseError = [NSError errorWithDomain: @"RCTVideo"
                                                                    code: RCTVideoErrorNoCertificateData
                                                                userInfo: @{
                                                                    NSLocalizedDescriptionKey: @"Error obtaining DRM license.",
                                                                    NSLocalizedFailureReasonErrorKey: @"No certificate data obtained from the specificied url.",
                                                                    NSLocalizedRecoverySuggestionErrorKey: @"Have you specified a valid 'certificateUrl'?"
                                                                }
                                                 ];
                        [self finishLoadingWithError:licenseError];
                        self->_requestingCertificateErrored = YES;
                    }
                });
                return YES;
            } else {
                NSError *licenseError = [NSError errorWithDomain: @"RCTVideo"
                                                            code: RCTVideoErrorNoCertificateURL
                                                        userInfo: @{
                                                            NSLocalizedDescriptionKey: @"Error obtaining DRM License.",
                                                            NSLocalizedFailureReasonErrorKey: @"No certificate URL has been found.",
                                                            NSLocalizedRecoverySuggestionErrorKey: @"Did you specified the prop certificateUrl?"
                                                        }
                                         ];
                return [self finishLoadingWithError:licenseError];
            }
        } else {
            NSError *licenseError = [NSError errorWithDomain: @"RCTVideo"
                                                        code: RCTVideoErrorNoFairplayDRM
                                                    userInfo: @{
                                                        NSLocalizedDescriptionKey: @"Error obtaining DRM license.",
                                                        NSLocalizedFailureReasonErrorKey: @"Not a valid DRM Scheme has found",
                                                        NSLocalizedRecoverySuggestionErrorKey: @"Have you specified the 'drm' 'type' as fairplay?"
                                                    }
                                     ];
            return [self finishLoadingWithError:licenseError];
        }
        
    } else {
        NSError *licenseError = [NSError errorWithDomain: @"RCTVideo"
                                                    code: RCTVideoErrorNoDRMData
                                                userInfo: @{
                                                    NSLocalizedDescriptionKey: @"Error obtaining DRM license.",
                                                    NSLocalizedFailureReasonErrorKey: @"No drm object found.",
                                                    NSLocalizedRecoverySuggestionErrorKey: @"Have you specified the 'drm' prop?"
                                                }
                                 ];
        return [self finishLoadingWithError:licenseError];
    }
    
    
    return NO;
}

- (NSData *)base64DataFromBase64String: (NSString *)base64String {
    if (base64String != nil) {
        // NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:base64String options:0];
        // NSString *decodedString = [[NSString alloc] initWithData:decodedData encoding:NSASCIIStringEncoding];
        // NSLog(@"%@", decodedString); // foo
        // return decodedString;
        // NSData from the Base64 encoded str
        NSData *base64Data = [[NSData alloc] initWithBase64EncodedString:base64String options:NSDataBase64DecodingIgnoreUnknownCharacters];
        return base64Data;
    }
    return nil;
}
#pragma mark - Picture in Picture

#if TARGET_OS_IOS
- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    if (self.onPictureInPictureStatusChanged) {
        self.onPictureInPictureStatusChanged(@{
            @"isActive": [NSNumber numberWithBool:false]
                                             });
    }
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    if (self.onPictureInPictureStatusChanged) {
        self.onPictureInPictureStatusChanged(@{
            @"isActive": [NSNumber numberWithBool:true]
                                             });
    }
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    
}

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController failedToStartPictureInPictureWithError:(NSError *)error {
    
}

- (NSString*)encodeStringTo64:(NSString*)fromString
{
    NSData *plainData = [fromString dataUsingEncoding:NSDataBase64DecodingIgnoreUnknownCharacters];
    NSString *base64String;
    if ([plainData respondsToSelector:@selector(base64EncodedStringWithOptions:)]) {
        base64String = [plainData base64EncodedStringWithOptions:kNilOptions];  // iOS 7+
    } else {
        base64String = [plainData base64Encoding];                              // pre iOS7
    }
    
    return base64String;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    NSAssert(_restoreUserInterfaceForPIPStopCompletionHandler == NULL, @"restoreUserInterfaceForPIPStopCompletionHandler was not called after picture in picture was exited.");
    if (self.onRestoreUserInterfaceForPictureInPictureStop) {
        self.onRestoreUserInterfaceForPictureInPictureStop(@{});
    }
    _restoreUserInterfaceForPIPStopCompletionHandler = completionHandler;
}
#endif

@end

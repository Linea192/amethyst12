//
//  DONavigationController.m
//  Amethyst (Dopamine UI port)
//
//  Ported from Dopamine by tomt000 — MIT License
//  https://github.com/opa334/dopamine
//  Adapted: root view controller is Amethyst's MainController, and the
//  dark-mode override is guarded for iOS 12.
//

#import "DONavigationController.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import "../MainController.h"
#import "DOGlobalAppearance.h"
#import "DOThemeManager.h"

@interface DONavigationController ()

@property (nonatomic) UIImageView *backgroundImageView;
@property (nonatomic) MainController *mainView;
@property (nonatomic) DOModalBackAction *backAction;

@end

@interface UINavigationController (Private)
- (CGRect)_frameForViewController:(id)arg1;
@end

#pragma mark - Warp streak image

// CAEmitterCell cannot rotate its contents (it has no rotation/transform
// property — only "spin", which is a continuous angular velocity), so the
// streak image is generated once per travel direction: the bright head is
// always at the end that leads the motion.
static UIImage *DONavWarpStreakImage(BOOL headRight)
{
    const CGFloat length = 220.0f;
    const CGFloat thickness = 5.0f;

    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(length, thickness)];

    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef cg = ctx.CGContext;

        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGFloat components[12] = {
            1.0f, 1.0f, 1.0f, 0.0f,   // tail: fully transparent
            1.0f, 1.0f, 1.0f, 0.5f,   // middle
            1.0f, 1.0f, 1.0f, 1.0f,   // head: solid white
        };
        CGFloat locations[3] = { 0.0f, 0.6f, 1.0f };
        CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, locations, 3);
        CGColorSpaceRelease(space);

        if (gradient != NULL) {
            UIBezierPath *capsule =
                [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.0f, 0.0f, length, thickness)
                                        cornerRadius:thickness / 2.0f];
            CGContextSaveGState(cg);
            [capsule addClip];
            if (headRight) {
                CGContextDrawLinearGradient(cg, gradient,
                                            CGPointMake(0.0f, thickness / 2.0f),
                                            CGPointMake(length, thickness / 2.0f), 0);
            } else {
                CGContextDrawLinearGradient(cg, gradient,
                                            CGPointMake(length, thickness / 2.0f),
                                            CGPointMake(0.0f, thickness / 2.0f), 0);
            }
            CGGradientRelease(gradient);
            CGContextRestoreGState(cg);
        }
    }];
}

@implementation DONavigationController

- (void)viewDidLoad
{
    [self setupBackground];
    [super viewDidLoad];
    [self setNavigationBarHidden:YES];
    [self pushViewController:(self.mainView = [[MainController alloc] init]) animated:NO];
    [self setDelegate:self];
    if (@available(iOS 13.0, *)) {
        [self setOverrideUserInterfaceStyle:UIUserInterfaceStyleDark];
    }
}

- (void)setupBackground
{
    DOTheme *theme = [[DOThemeManager sharedInstance] enabledTheme];

    self.view.backgroundColor = [UIColor blackColor];
    self.backgroundImageView = [[UIImageView alloc] init];
    self.backgroundImageView.image = [theme image];
    self.backgroundImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.backgroundImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.backgroundImageView.userInteractionEnabled = NO;
    self.backgroundImageView.layer.zPosition = -1;

    [self.view insertSubview:self.backgroundImageView atIndex:0];

    [NSLayoutConstraint activateConstraints:@[
        [self.backgroundImageView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.backgroundImageView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.backgroundImageView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:-100],
        [self.backgroundImageView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:100],
    ]];

    self.backAction = [[DOModalBackAction alloc] initWithAction:^{
        [self popViewControllerAnimated:YES];
    }];
    self.backAction.translatesAutoresizingMaskIntoConstraints = NO;
    self.backAction.hidden = YES;

    [self.view insertSubview:self.backAction atIndex:2];

    [NSLayoutConstraint activateConstraints:@[
        [self.backAction.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.backAction.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.backAction.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.backAction.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)setBackgroundDimmed:(BOOL)dimmed
{
    [UIView animateWithDuration:0.3 animations:^{
        self.backgroundImageView.alpha = dimmed ? 0.4 : 1;
    }];
    self.backgroundImageView.userInteractionEnabled = dimmed;
    self.backAction.hidden = !dimmed;
}

#pragma mark - Warp streaks

// Plays a short "warp speed" light-streak burst aligned with the direction
// the transition is moving in. All cell parameters use real CAEmitterCell
// API: opacity comes from the alpha component of the color multiplier, and
// the travel direction from emissionLongitude.
- (void)playWarpStreaksForwards:(BOOL)forwards
{
    CGRect bounds = self.view.bounds;
    if (CGRectIsEmpty(bounds)) {
        return;
    }

    CGFloat width = bounds.size.width;
    CGFloat height = bounds.size.height;

    // Push slides content leftwards, pop slides it back rightwards.
    CGFloat longitude = forwards ? (CGFloat)M_PI : 0.0f;
    CGFloat spawnEdgeX = forwards ? width + 14.0f : -14.0f;
    UIImage *streak = DONavWarpStreakImage(!forwards);

    CAEmitterLayer *warp = [CAEmitterLayer layer];
    warp.frame = bounds;
    warp.zPosition = 50.0f;
    // Without this the layer renders an initial burst of already-aged particles.
    warp.beginTime = CACurrentMediaTime();
    warp.emitterShape = kCAEmitterLayerRectangle;
    warp.emitterPosition = CGPointMake(spawnEdgeX, height / 2.0f);
    warp.emitterSize = CGSizeMake(4.0f, height);

    CAEmitterCell *main = [CAEmitterCell emitterCell];
    main.name = @"warpMain";
    main.contents = (__bridge id)streak.CGImage;
    main.birthRate = 24.0f;
    main.lifetime = 0.5f;
    main.lifetimeRange = 0.15f;
    main.velocity = width * 2.3f;
    main.velocityRange = width * 0.5f;
    main.emissionLongitude = longitude;
    main.emissionRange = 0.06f;
    main.scale = 0.9f;
    main.scaleRange = 0.45f;
    // CAEmitterCell has no alpha property; the alpha component of "color"
    // (which multiplies the particle image) carries the opacity.
    main.color = [UIColor colorWithWhite:1.0f alpha:0.95f].CGColor;
    main.alphaSpeed = -0.35f;

    CAEmitterCell *distant = [CAEmitterCell emitterCell];
    distant.name = @"warpDistant";
    distant.contents = (__bridge id)streak.CGImage;
    distant.birthRate = 32.0f;
    distant.lifetime = 0.55f;
    distant.lifetimeRange = 0.15f;
    distant.velocity = width * 1.8f;
    distant.velocityRange = width * 0.45f;
    distant.emissionLongitude = longitude;
    distant.emissionRange = 0.08f;
    distant.scale = 0.42f;
    distant.scaleRange = 0.2f;
    distant.color = [UIColor colorWithWhite:1.0f alpha:0.55f].CGColor;
    distant.alphaSpeed = -0.5f;

    warp.emitterCells = @[main, distant];
    [self.view.layer addSublayer:warp];

    // Stop spawning once the transition is over, then drop the layer after
    // the last streaks have died out. Named cells are addressed via KVC,
    // which is the documented way to mutate a live emitter.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [warp setValue:@0.0f forKeyPath:@"emitterCells.warpMain.birthRate"];
        [warp setValue:@0.0f forKeyPath:@"emitterCells.warpDistant.birthRate"];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [warp removeFromSuperlayer];
    });
}

#pragma mark - Delegate

- (id<UIViewControllerAnimatedTransitioning>)navigationController:(UINavigationController *)navigationController
           animationControllerForOperation:(UINavigationControllerOperation)operation
                        fromViewController:(UIViewController *)fromVC
                          toViewController:(UIViewController *)toVC {

    BOOL forwards = (operation == UINavigationControllerOperationPush);
    if (self.viewIfLoaded.window != nil) {
        [self playWarpStreaksForwards:forwards];
    }

    if (fromVC.class == MainController.class || toVC.class == MainController.class)
        return [[DOModalTransitionScale alloc] initForwards: forwards];
    return [[DOModalTransitionPush alloc] initForwards: forwards];
}

- (void)navigationController:(UINavigationController *)navigationController willShowViewController:(UIViewController *)viewController animated:(BOOL)animated
{
    [self setBackgroundDimmed:![viewController isKindOfClass:[MainController class]]];
    [self.backAction setIgnoreFrame:[self _frameForViewController:viewController]];
}

#pragma mark - Overrides

- (CGRect)_frameForViewController:(id)viewController
{
    CGRect orig = [super _frameForViewController: viewController];
    if ([[viewController class] isEqual: [MainController class]])
        return orig;

    orig.size.width = fmin(orig.size.width - UI_MODAL_PADDING * 2, UI_IPAD_MAX_WIDTH);
    orig.size.height *= [DOGlobalAppearance isSmallDevice] ? 0.8 : 0.7;
    orig.origin.x = (self.view.frame.size.width - orig.size.width) / 2;
    orig.origin.y = (self.view.frame.size.height - orig.size.height) / 2;

    return orig;
}

@end

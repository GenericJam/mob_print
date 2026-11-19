/* mob_print_nif — iOS system PDF print plugin NIF (Objective-C).
 *
 * Presents UIPrintInteractionController with an existing PDF file URL
 * (printingItem) from the host's foreground-active key window / top presented
 * view controller. Requires no permissions or Info.plist keys.
 *
 * Returns :ok once the print UI has been requested (not once the job finishes
 * printing; no completion message is sent back to the caller), or
 * {:error, :not_found | :no_activity | :failed | :unsupported}.
 *
 * Runs on a dirty IO scheduler (ERL_NIF_DIRTY_JOB_IO_BOUND) and waits up to 2 s
 * for the main-thread presentation hand-off (running inline if already on the
 * main thread).
 *
 * Compiled as ObjC (-fobjc-arc) via the plugin objc-NIF path (manifest
 * lang: :objc, platform: :ios). Registered as Erlang module mob_print_nif via
 * ERL_NIF_INIT.
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <erl_nif.h>

static ERL_NIF_TERM print_error_tuple(ErlNifEnv *env, const char *reason) {
  return enif_make_tuple2(env, enif_make_atom(env, "error"),
                          enif_make_atom(env, reason));
}

static NSString *print_string_from_binary(ErlNifEnv *env, ERL_NIF_TERM term) {
  ErlNifBinary bin;
  if (!enif_inspect_binary(env, term, &bin)) {
    return nil;
  }
  return [[NSString alloc] initWithBytes:bin.data
                                  length:bin.size
                                encoding:NSUTF8StringEncoding];
}

// Locate the top presented UIViewController in a foreground-active window
// scene (multi-scene aware, following the mob_sms pattern). Returns nil if the
// app is not foreground-active or the top controller is mid-transition.
static UIViewController *print_top_view_controller(void) {
  UIWindow *targetWindow = nil;
  NSSet<UIScene *> *scenes = UIApplication.sharedApplication.connectedScenes;
  for (UIScene *scene in scenes) {
    if (![scene isKindOfClass:[UIWindowScene class]]) continue;
    if (scene.activationState != UISceneActivationStateForegroundActive) continue;
    UIWindowScene *ws = (UIWindowScene *)scene;
    for (UIWindow *w in ws.windows) {
      if (w.isKeyWindow) {
        targetWindow = w;
        break;
      }
    }
    if (targetWindow != nil) break;
  }
  if (targetWindow == nil) {
    for (UIScene *scene in scenes) {
      if (![scene isKindOfClass:[UIWindowScene class]]) continue;
      if (scene.activationState != UISceneActivationStateForegroundActive) continue;
      UIWindowScene *ws = (UIWindowScene *)scene;
      if (ws.windows.count > 0) {
        targetWindow = ws.windows.firstObject;
        break;
      }
    }
  }
  if (targetWindow == nil) return nil;

  UIViewController *vc = targetWindow.rootViewController;
  while (vc.presentedViewController != nil) {
    vc = vc.presentedViewController;
  }
  if (vc == nil || vc.isBeingDismissed || vc.isBeingPresented) return nil;
  return vc;
}

// Must run on the main thread. Returns NULL on success, or one of the fixed
// error reason strings.
static const char *print_present_on_main(NSString *path, NSString *title) {
  if (![UIPrintInteractionController isPrintingAvailable]) {
    return "unsupported";
  }

  NSURL *url = [NSURL fileURLWithPath:path];
  if (url == nil || ![UIPrintInteractionController canPrintURL:url]) {
    return "failed";
  }

  UIViewController *host = print_top_view_controller();
  if (host == nil || host.view == nil || host.view.window == nil) {
    return "no_activity";
  }

  UIPrintInteractionController *controller =
      [UIPrintInteractionController sharedPrintController];
  if (controller == nil) {
    return "unsupported";
  }

  UIPrintInfo *info = [UIPrintInfo printInfo];
  info.outputType = UIPrintInfoOutputGeneral;
  NSString *jobName =
      (title.length > 0) ? title
                         : path.lastPathComponent.stringByDeletingPathExtension;
  info.jobName = (jobName.length > 0) ? jobName : path.lastPathComponent;
  controller.printInfo = info;
  controller.printingItem = url;

  UIPrintInteractionCompletionHandler completion =
      ^(UIPrintInteractionController *printController, BOOL completed,
        NSError *error) {
        (void)printController;
        (void)completed;
        if (error != nil) {
          NSLog(@"[mob_print] print interaction failed: %@", error);
        }
      };

  BOOL presented = NO;
  if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
    CGRect bounds = host.view.bounds;
    CGRect anchor =
        CGRectMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds), 1.0, 1.0);
    presented = [controller presentFromRect:anchor
                                     inView:host.view
                                   animated:YES
                          completionHandler:completion];
  } else {
    presented = [controller presentAnimated:YES completionHandler:completion];
  }

  return presented ? NULL : "failed";
}

// print_pdf(path :: binary, title :: binary) :: :ok | {:error, reason}
static ERL_NIF_TERM nif_print_pdf(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]) {
  (void)argc;
  @autoreleasepool {
    NSString *path = print_string_from_binary(env, argv[0]);
    NSString *title = print_string_from_binary(env, argv[1]);
    if (path == nil || title == nil) {
      return enif_make_badarg(env);
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir] || isDir ||
        ![fm isReadableFileAtPath:path]) {
      return print_error_tuple(env, "not_found");
    }

    const char *reason = NULL;
    if ([NSThread isMainThread]) {
      reason = print_present_on_main(path, title);
    } else {
      dispatch_semaphore_t sem = dispatch_semaphore_create(0);
      __block const char *main_reason = NULL;
      dispatch_async(dispatch_get_main_queue(), ^{
        main_reason = print_present_on_main(path, title);
        dispatch_semaphore_signal(sem);
      });
      dispatch_time_t timeout =
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC));
      if (dispatch_semaphore_wait(sem, timeout) == 0) {
        reason = main_reason;
      }
      // If the wait times out after dispatch_async succeeded, the presentation
      // request is already queued on the main queue; treat "asked for" as :ok
      // (matching Android's UI_WAIT_MS timeout behaviour) without reading
      // main_reason concurrently.
    }

    if (reason == NULL) {
      return enif_make_atom(env, "ok");
    }
    return print_error_tuple(env, reason);
  }
}

// ── Registration ──────────────────────────────────────────────────────────
static ErlNifFunc nif_funcs[] = {
    {"print_pdf", 2, nif_print_pdf, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(mob_print_nif, nif_funcs, NULL, NULL, NULL, NULL)

#import <Foundation/Foundation.h>
#include <notify.h>

extern void rex_agent_start(void);
extern void rex_agent_snapshot(void);

__attribute__((constructor)) static void rex_agent_load(void) {
    if (getenv("REX_AGENT_ROOT") == NULL) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        rex_agent_start();
        int token = 0;
        notify_register_dispatch("dev.rexagent.snapshot", &token, dispatch_get_main_queue(), ^(int unused) {
            rex_agent_snapshot();
        });
    });
}

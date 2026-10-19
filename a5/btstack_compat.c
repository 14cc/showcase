// carplay_bt.m 是按老版 libBTstack 的接口写的（run_loop_*、rfcomm_accept_connection 这类名字），
// 上游无根包直接带老库。我们自己从 btstack-rootless 源码编库时，新版把这些改了名，
// 程序运行时就会报 "symbol not found"。这里把老名字接到新实现上。
// 命令结构体（rfcomm_*_cmd 等）的老名字用链接参数 -alias 补，见 build-a5.sh 的 BTALIAS。
#include <stdint.h>
#include "btstack_run_loop.h"
#include "btstack_run_loop_posix.h"
#include "btstack_run_loop_corefoundation.h"

// 老版 RUN_LOOP_TYPE: 1 = POSIX, 2 = COCOA
void run_loop_init(int type){
    btstack_run_loop_init(type == 2 ? btstack_run_loop_corefoundation_get_instance()
                                    : btstack_run_loop_posix_get_instance());
}
void run_loop_execute(void){ btstack_run_loop_execute(); }
void run_loop_set_timer(void *ts, uint32_t ms){ btstack_run_loop_set_timer((btstack_timer_source_t *)ts, ms); }
void run_loop_set_timer_handler(void *ts, void (*process)(void *)){
    btstack_run_loop_set_timer_handler((btstack_timer_source_t *)ts, (void (*)(btstack_timer_source_t *))process);
}
void run_loop_add_timer(void *ts){ btstack_run_loop_add_timer((btstack_timer_source_t *)ts); }
int  run_loop_remove_timer(void *ts){ return btstack_run_loop_remove_timer((btstack_timer_source_t *)ts); }

#ifndef MEMVIEW_H
#define MEMVIEW_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint64_t memview_calc_min_required_memory(uint64_t bytes_for_stacktrace);
int memview_init(char* memview_resource_buffer, uint64_t buffer_size, uint64_t bytes_for_stacktrace);
void memview_deinit();
void memview_wait_for_connection();
void memview_pump_message_queue();
void memview_msg_frame();
uint64_t memview_msg_stringid(const uint8_t* string_buffer, uint64_t string_length);
void memview_msg_stack(uint64_t stack_id, const uint8_t* string_buffer, uint64_t string_length);
void memview_msg_alloc(uint64_t address, uint64_t size, uint64_t region_id);
void memview_msg_free(uint64_t address);

#ifdef __cplusplus
}
#endif

#endif // MEMVIEW_H

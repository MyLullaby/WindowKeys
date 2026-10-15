#ifndef WINDOWKEYS_DDC_REPLY_H
#define WINDOWKEYS_DDC_REPLY_H
#include <stdbool.h>
#include <stdint.h>

static inline bool decodeDDCReply(const uint8_t reply[12], uint8_t code, int *current, int *maximum) {
    uint8_t checksum = 0x50;
    for (int i = 0; i < 11; i++) checksum ^= reply[i];
    if (reply[0] != 0x6e || reply[1] != 0x88 || reply[2] != 0x02 ||
        reply[3] != 0 || reply[4] != code || checksum != 0) return false;
    *maximum = (reply[6] << 8) | reply[7];
    *current = (reply[8] << 8) | reply[9];
    return *maximum > 0 && *current <= *maximum;
}
#endif

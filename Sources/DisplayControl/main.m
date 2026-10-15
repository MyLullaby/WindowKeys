@import Foundation;
@import IOKit;
#include "ioregistry.h"
#include "DDCReply.h"
#include <unistd.h>

extern IOReturn IOAVServiceReadI2C(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);

static NSDictionary *readValue(DDCTransport transport, uint8_t code) {
    for (int attempt = 0; attempt < 3; attempt++) {
        uint8_t request[] = {0x82, 0x01, code, 0x6e ^ 0x51 ^ 0x82 ^ 0x01 ^ code};
        usleep(50000);
        if (IOAVServiceWriteI2C(transport.service, transport.chipAddress, 0x51, request, sizeof(request))) continue;
        usleep(50000);
        uint8_t reply[12] = {};
        if (IOAVServiceReadI2C(transport.service, transport.chipAddress, 0x51, reply, sizeof(reply))) continue;
        int current, maximum;
        if (decodeDDCReply(reply, code, &current, &maximum)) {
            return @{@"current": @(current), @"maximum": @(maximum)};
        }
    }
    return nil;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        DisplayInfos displays[MAX_DISPLAYS] = {};
        unsigned count = getOnlineDisplayInfos(displays);
        if (argc == 2 && strcmp(argv[1], "list") == 0) {
            NSMutableArray *result = [NSMutableArray array];
            for (unsigned i = 0; i < count; i++) {
                if (CGDisplayIsBuiltin(displays[i].id)) continue;
                [result addObject:@{@"id": displays[i].uuid,
                                    @"name": displays[i].productName ?: @"External Display"}];
            }
            NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
            fwrite(data.bytes, 1, data.length, stdout);
            return 0;
        }
        if (argc != 3 && argc != 5) return 1;
        DDCTransport transport = {};
        for (unsigned i = 0; i < count; i++) {
            if (!CGDisplayIsBuiltin(displays[i].id) && [displays[i].uuid isEqualToString:@(argv[2])]) {
                transport = getDisplayDDCTransport(&displays[i]);
                break;
            }
        }
        if (!transport.service) return 2;
        if (argc == 5 && strcmp(argv[1], "set") == 0) {
            uint8_t code = strcmp(argv[3], "brightness") == 0 ? 0x10 : strcmp(argv[3], "volume") == 0 ? 0x62 : 0;
            char *end;
            long value = strtol(argv[4], &end, 10);
            NSDictionary *before = code ? readValue(transport, code) : nil;
            if (!before || end == argv[4] || *end || value < 0 || value > [before[@"maximum"] intValue]) return 3;
            uint8_t packet[] = {0x84, 0x03, code, value >> 8, value & 255, 0};
            packet[5] = 0x6e ^ 0x51;
            for (int i = 0; i < 5; i++) packet[5] ^= packet[i];
            usleep(50000);
            if (IOAVServiceWriteI2C(transport.service, transport.chipAddress, 0x51, packet, sizeof(packet))) return 4;
            usleep(150000);
            NSDictionary *after = readValue(transport, code);
            if (!after || [after[@"current"] intValue] != value) return 5;
        } else if (argc != 3 || strcmp(argv[1], "read") != 0) {
            return 1;
        }
        NSDictionary *result = @{@"brightness": readValue(transport, 0x10) ?: [NSNull null],
                                 @"volume": readValue(transport, 0x62) ?: [NSNull null]};
        CFRelease(transport.service);
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        fwrite(data.bytes, 1, data.length, stdout);
        return 0;
    }
}

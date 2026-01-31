#!/usr/bin/env python3
import argparse
import socket
import struct
import time

TLV_TENANT = 0x4C52
TLV_AUTH_NONE = 0x414E
PDU_RATE_REQUEST = 0x5452
PDU_RATE_RESPONSE = 0x5252

TENANT_TLV_LEN = 40
PDU_HEADER_LEN = 8

GUARD_BLOCK_LEN = 40
RESOURCE_BLOCK_LEN = 28


def le16(b):
    return struct.unpack_from('<H', b, 0)[0]


def le32(b):
    return struct.unpack_from('<I', b, 0)[0]


def le64(b):
    return struct.unpack_from('<Q', b, 0)[0]


def write_le16(v):
    return struct.pack('<H', v)


def write_le32(v):
    return struct.pack('<I', v)


def write_le64(v):
    return struct.pack('<Q', v)


def build_rate_response(request, server_id, keep_port=True):
    # Tenant TLV
    if len(request) < 4 + TENANT_TLV_LEN:
        return None
    tlv_type = le16(request[0:2])
    tlv_size = le16(request[2:4])
    if tlv_type != TLV_TENANT or tlv_size < TENANT_TLV_LEN:
        return None
    tenant_body = request[4:4 + (tlv_size - 4)]
    if len(tenant_body) < (TENANT_TLV_LEN - 4):
        return None

    req_key_id = le64(tenant_body[0:8])
    unique_id = tenant_body[8:24]

    # Auth TLV header
    pos = 4 + (tlv_size - 4)
    if len(request) < pos + 4:
        return None
    auth_type = le16(request[pos:pos + 2])
    auth_size = le16(request[pos + 2:pos + 4])
    pos += 4
    if auth_type != TLV_AUTH_NONE or auth_size != 4:
        return None

    # PDU header
    if len(request) < pos + PDU_HEADER_LEN:
        return None
    pdu_type = le16(request[pos:pos + 2])
    pdu_size = le16(request[pos + 2:pos + 4])
    if pdu_type != PDU_RATE_REQUEST:
        return None
    if pdu_size < PDU_HEADER_LEN or len(request) < pos + pdu_size:
        return None
    pdu_body = request[pos + PDU_HEADER_LEN:pos + pdu_size]

    if len(pdu_body) < 4:
        return None
    guard_count = le16(pdu_body[0:2])
    resource_count = le16(pdu_body[2:4])

    offset = 4
    guards = []
    for _ in range(guard_count):
        if len(pdu_body) < offset + GUARD_BLOCK_LEN:
            return None
        block = bytearray(pdu_body[offset:offset + GUARD_BLOCK_LEN])
        # current_latency = 0
        block[36:40] = write_le32(0)
        guards.append(block)
        offset += GUARD_BLOCK_LEN

    resources = []
    for _ in range(resource_count):
        if len(pdu_body) < offset + RESOURCE_BLOCK_LEN:
            return None
        block = bytearray(pdu_body[offset:offset + RESOURCE_BLOCK_LEN])
        # tokens_requested (deficit) = 0, actual_rate = 0
        block[20:24] = write_le32(0)
        block[24:26] = write_le16(0)
        resources.append(block)
        offset += RESOURCE_BLOCK_LEN

    body = bytearray()
    body += write_le16(guard_count)
    body += write_le16(resource_count)
    for g in guards:
        body += g
    for r in resources:
        body += r

    pdu = bytearray()
    pdu += write_le16(PDU_RATE_RESPONSE)
    pdu += write_le16(PDU_HEADER_LEN + len(body))
    pdu += write_le16(0)
    pdu += write_le16(0)
    pdu += body

    # Tenant TLV (response)
    tenant = bytearray()
    tenant += write_le16(TLV_TENANT)
    tenant += write_le16(TENANT_TLV_LEN)
    tenant += write_le64(server_id)  # server_id in response
    tenant += unique_id
    tenant += write_le64(int(time.time() * 1000))
    tenant += struct.pack('B', 1 if keep_port else 0)
    tenant += struct.pack('B', 0)  # tenant_mgmt_flag
    tenant += b'\x00\x00'

    auth = bytearray()
    auth += write_le16(TLV_AUTH_NONE)
    auth += write_le16(4)

    return tenant + auth + pdu


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bind', default='127.0.0.1:8080')
    parser.add_argument('--server-id', type=int, default=1)
    parser.add_argument('--keep-port', action='store_true')
    args = parser.parse_args()

    host, port = args.bind.rsplit(':', 1)
    port = int(port)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((host, port))
    print(f"mock_rl_server listening on {host}:{port}")

    while True:
        data, addr = sock.recvfrom(4096)
        resp = build_rate_response(data, args.server_id, keep_port=args.keep_port)
        if resp is None:
            continue
        sock.sendto(resp, addr)


if __name__ == '__main__':
    main()

# RNDIS protocol notes

Both drivers implement this protocol: in Swift (`Sources/TetheringCore/RNDIS/`) and in portable C++
for the DriverKit extension (`Driver/RNDISCodec.cpp`).

Reference: Microsoft *[MS-RNDIS]: Remote Network Driver Interface Specification*. All fields are
32-bit little-endian.

## USB function

| Interface | Class / Subclass / Protocol | Endpoints |
|---|---|---|
| Communication (control) | `E0/01/03` (most Android) or `02/02/FF` | 1 × interrupt IN (notifications) |
| CDC Data | `0A/00/00` | bulk IN + bulk OUT |

Phones that use **CDC-NCM** (`02/0D/00`) work natively on macOS; the app only reports them.

## Control channel

| Direction | Request | bmRequestType | bRequest | wIndex |
|---|---|---|---|---|
| Host → device | `SEND_ENCAPSULATED_COMMAND` | `0x21` | `0x00` | control interface number |
| Device → host | `GET_ENCAPSULATED_RESPONSE` | `0xA1` | `0x01` | control interface number |

After sending a command the device signals `RESPONSE_AVAILABLE` on the interrupt endpoint. This
implementation polls `GET_ENCAPSULATED_RESPONSE` instead (like Linux `rndis_host`), and answers
`KEEPALIVE_MSG` while it waits.

## Bring-up sequence

```
Host                                         Phone
 │── INITIALIZE_MSG (v1.0, MaxTransfer 16K) ──►│
 │◄─────────────── INITIALIZE_CMPLT ───────────│  MaxTransferSize, PacketAlignment
 │── QUERY_MSG OID_802_3_PERMANENT_ADDRESS ───►│
 │◄─────────────── QUERY_CMPLT (6-byte MAC) ───│  becomes the host-side MAC
 │── SET_MSG OID_GEN_CURRENT_PACKET_FILTER ───►│  DIRECTED | BROADCAST | ALL_MULTICAST (0x0D)
 │◄─────────────── SET_CMPLT ──────────────────│
 │═════════ bulk PACKET_MSG frames ═══════════│
 │── HALT_MSG (on disconnect) ────────────────►│
```

## Message layouts

| Message | Type | Layout (byte offsets) |
|---|---|---|
| `INITIALIZE_MSG` | `0x00000002` | 0 type · 4 len=24 · 8 reqID · 12 major · 16 minor · 20 maxTransfer |
| `INITIALIZE_CMPLT` | `0x80000002` | … 12 status · 16 major · 20 minor · 24 flags · 28 medium · 32 maxPackets · 36 maxTransfer · 40 alignment |
| `QUERY_MSG` / `SET_MSG` | `0x4` / `0x5` | 8 reqID · 12 OID · 16 bufLen · 20 bufOffset (from byte 8) · 24 VcHandle · 28 buffer |
| `QUERY_CMPLT` | `0x80000004` | 8 reqID · 12 status · 16 bufLen · 20 bufOffset (from byte 8) |
| `SET_CMPLT` | `0x80000005` | 8 reqID · 12 status |
| `KEEPALIVE_MSG` / `CMPLT` | `0x8` / `0x80000008` | 8 reqID (· 12 status) |
| `PACKET_MSG` | `0x00000001` | 4 len · 8 dataOffset (from byte 8, = 36) · 12 dataLen · … 44 Ethernet frame |

A single bulk-IN transfer may contain several concatenated `PACKET_MSG`s, possibly followed by
zero padding; `RNDISPacketCodec.unwrap` handles both.

## Key OIDs

| OID | Value |
|---|---|
| `OID_GEN_MAXIMUM_FRAME_SIZE` | `0x00010106` |
| `OID_GEN_CURRENT_PACKET_FILTER` | `0x0001010E` |
| `OID_GEN_MEDIA_CONNECT_STATUS` | `0x00010114` |
| `OID_802_3_PERMANENT_ADDRESS` | `0x01010101` |
| `OID_802_3_CURRENT_ADDRESS` | `0x01010102` |

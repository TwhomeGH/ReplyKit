import sys, collections

def parse_flv(path):
    with open(path, 'rb') as f:
        data = f.read()

    if data[:3] != b'FLV':
        print("Not an FLV file")
        return

    data_offset = int.from_bytes(data[5:9], 'big')   # DataOffset 在 bytes 5-8
    pos = data_offset + 4                              # 跳過 PreviousTagSize0

    audio_pts = []
    video_pts = []
    audio_sizes = []
    video_sizes = []
    aac_cc = collections.Counter()   # audio codec
    vcodec = collections.Counter()
    aac_config_done = False
    tag_count = 0

    print(f"header first 32 bytes: {data[:32].hex()}")
    print(f"data_offset: {data_offset}")
    while pos + 11 <= len(data):
        tag_type = data[pos]
        data_size = int.from_bytes(data[pos+1:pos+4], 'big')
        ts = int.from_bytes(data[pos+4:pos+7], 'big') | (data[pos+7] << 24)
        stream_id = int.from_bytes(data[pos+8:pos+11], 'big')
        if pos + 11 + data_size + 4 > len(data):
            print(f"break at pos={pos}: type={tag_type} size={data_size} ts={ts} remaining={len(data)-pos}")
            break
        if tag_count < 5:
            print(f"tag#{tag_count}: type={tag_type} size={data_size} ts={ts} sid={stream_id} pos={pos}")
        payload = data[pos+11:pos+11+data_size]

        if tag_type == 8:  # audio
            audio_pts.append(ts)
            audio_sizes.append(data_size)
            if payload:
                aac_cc[payload[0] >> 4] += 1
                if not aac_config_done:
                    aac_config_done = True
                    print(f"AAC first audio payload: {payload.hex()} size={data_size}")
                    if data_size >= 2 and (payload[0] & 0x0F) == 10:
                        asc = (payload[1] << 3) | (payload[2] >> 5) if data_size >= 3 else (payload[1] >> 3)
                        # ASC: audioObjectType(5) sampleRateIndex(4) channelConfig(4)
                        if data_size >= 2:
                            aot = payload[1] >> 3
                            sri = ((payload[1] & 0x07) << 1) | (payload[2] >> 7) if data_size >= 3 else (payload[1] & 0x07)
                            rates = [96000,88200,64000,48000,44100,32000,24000,22050,16000,12000,11025,8000,7350]
                            if sri < len(rates):
                                print(f"AAC: audioObjectType={aot} sampleRateIndex={sri} -> {rates[sri]} Hz")
        elif tag_type == 9:  # video
            video_pts.append(ts)
            video_sizes.append(data_size)
            if payload:
                vcodec[payload[0] >> 4] += 1

        pos += 11 + data_size + 4
        tag_count += 1

    print(f"file size: {len(data)} bytes, tags: {tag_count}")
    print(f"audio tags: {len(audio_pts)}, video tags: {len(video_pts)}")
    print(f"audio codec (4-bit): {dict(aac_cc)}")
    print(f"video codec (4-bit): {dict(vcodec)}")
    if audio_pts:
        dur = (audio_pts[-1] - audio_pts[0]) / 1000.0
        print(f"audio span: {dur:.2f}s, frames/s: {len(audio_pts)/max(dur,0.001):.2f}")
    if video_pts:
        dur = (video_pts[-1] - video_pts[0]) / 1000.0
        print(f"video span: {dur:.2f}s, frames/s: {len(video_pts)/max(dur,0.001):.2f}")

    def analyze(name, pts, sizes, frame_ms):
        print(f"\n=== {name} (expected ~{frame_ms}ms/frame) ===")
        if len(pts) < 2:
            print("not enough tags")
            return
        deltas = [pts[i+1] - pts[i] for i in range(len(pts)-1)]
        neg = [d for d in deltas if d < 0]
        zero = [d for d in deltas if d == 0]
        # gaps bigger than 2x expected frame time
        gap_thr = int(frame_ms * 2.5)
        gaps = [(i, pts[i], pts[i+1], d) for i, d in enumerate(deltas) if d > gap_thr]
        big = [(i, pts[i], pts[i+1], d) for i, d in enumerate(deltas) if d > 500]
        print(f"deltas: min={min(deltas)} max={max(deltas)} avg={sum(deltas)/len(deltas):.1f}ms")
        print(f"negative deltas (PTS reorder/backwards): {len(neg)}")
        print(f"zero deltas: {len(zero)}")
        print(f"gaps >{gap_thr}ms: {len(gaps)}")
        print(f"gaps >500ms: {len(big)}")
        if gaps:
            print("first 15 gaps (idx, from_ms, to_ms, delta_ms):")
            for g in gaps[:15]:
                print(f"  {g}")
        # continuity: how many expected frames are missing
        span_ms = pts[-1] - pts[0]
        expected = span_ms / frame_ms
        actual = len(pts) - 1
        print(f"missing frames vs {frame_ms}ms cadence: expected~{expected:.0f}, actual deltas={actual}, missing={expected-actual:.0f}")

    analyze("AUDIO", audio_pts, audio_sizes, 23)
    analyze("VIDEO", video_pts, video_sizes, 33)

    # A/V sync: first/last audio vs video pts
    if audio_pts and video_pts:
        a0, a1 = audio_pts[0], audio_pts[-1]
        v0, v1 = video_pts[0], video_pts[-1]
        print(f"\n=== A/V ===")
        print(f"audio first={a0} last={a1}; video first={v0} last={v1}")
        print(f"audio span={(a1-a0)/1000:.2f}s  video span={(v1-v0)/1000:.2f}s")

if __name__ == '__main__':
    parse_flv(sys.argv[1] if len(sys.argv) > 1 else 'live_probe2.flv')

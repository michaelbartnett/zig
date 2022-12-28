const std = @import("../../std.zig");
const tls = std.crypto.tls;
const Client = @This();
const net = std.net;
const mem = std.mem;
const crypto = std.crypto;
const assert = std.debug.assert;

const ApplicationCipher = tls.ApplicationCipher;
const CipherSuite = tls.CipherSuite;
const ContentType = tls.ContentType;
const HandshakeType = tls.HandshakeType;
const CipherParams = tls.CipherParams;
const max_ciphertext_len = tls.max_ciphertext_len;
const hkdfExpandLabel = tls.hkdfExpandLabel;

application_cipher: ApplicationCipher,
read_seq: u64,
write_seq: u64,
/// The size is enough to contain exactly one TLSCiphertext record.
partially_read_buffer: [tls.max_ciphertext_record_len]u8,
/// The number of partially read bytes inside `partiall_read_buffer`.
partially_read_len: u15,
eof: bool,

/// `host` is only borrowed during this function call.
pub fn init(stream: net.Stream, host: []const u8) !Client {
    const kp = crypto.dh.X25519.KeyPair.create(null) catch |err| switch (err) {
        // Only possible to happen if the private key is all zeroes.
        error.IdentityElement => return error.InsufficientEntropy,
    };

    // random (u32)
    var rand_buf: [32]u8 = undefined;
    crypto.random.bytes(&rand_buf);

    const extensions_header = [_]u8{
        // Extensions byte length
        undefined, undefined,

        // Extension: supported_versions (only TLS 1.3)
        0, 43, // ExtensionType.supported_versions
        0x00, 0x05, // byte length of this extension payload
        0x04, // byte length of supported versions
        0x03, 0x04, // TLS 1.3
        0x03, 0x03, // TLS 1.2

        // Extension: signature_algorithms
        0, 13, // ExtensionType.signature_algorithms
        0x00, 0x22, // byte length of this extension payload
        0x00, 0x20, // byte length of signature algorithms list
        0x04, 0x01, // rsa_pkcs1_sha256
        0x05, 0x01, // rsa_pkcs1_sha384
        0x06, 0x01, // rsa_pkcs1_sha512
        0x04, 0x03, // ecdsa_secp256r1_sha256
        0x05, 0x03, // ecdsa_secp384r1_sha384
        0x06, 0x03, // ecdsa_secp521r1_sha512
        0x08, 0x04, // rsa_pss_rsae_sha256
        0x08, 0x05, // rsa_pss_rsae_sha384
        0x08, 0x06, // rsa_pss_rsae_sha512
        0x08, 0x07, // ed25519
        0x08, 0x08, // ed448
        0x08, 0x09, // rsa_pss_pss_sha256
        0x08, 0x0a, // rsa_pss_pss_sha384
        0x08, 0x0b, // rsa_pss_pss_sha512
        0x02, 0x01, // rsa_pkcs1_sha1
        0x02, 0x03, // ecdsa_sha1

        // Extension: supported_groups
        0, 10, // ExtensionType.supported_groups
        0x00, 0x0c, // byte length of this extension payload
        0x00, 0x0a, // byte length of supported groups list
        0x00, 0x17, // secp256r1
        0x00, 0x18, // secp384r1
        0x00, 0x19, // secp521r1
        0x00, 0x1D, // x25519
        0x00, 0x1E, // x448

        // Extension: key_share
        0, 51, // ExtensionType.key_share
        0, 38, // byte length of this extension payload
        0, 36, // byte length of client_shares
        0x00, 0x1D, // NamedGroup.x25519
        0, 32, // byte length of key_exchange
    } ++ kp.public_key ++ [_]u8{

        // Extension: server_name
        0, 0, // ExtensionType.server_name
        undefined, undefined, // byte length of this extension payload
        undefined, undefined, // server_name_list byte count
        0x00, // name_type
        undefined, undefined, // host name len
    };

    var hello_header = [_]u8{
        // Plaintext header
        @enumToInt(ContentType.handshake),
        0x03, 0x01, // legacy_record_version
        undefined,                              undefined, // Plaintext fragment length (u16)

        // Handshake header
        @enumToInt(HandshakeType.client_hello),
        undefined, undefined, undefined, // handshake length (u24)

        // ClientHello
        0x03, 0x03, // legacy_version
    } ++ rand_buf ++ [1]u8{0} ++
        int2(cipher_suites.len) ++ cipher_suites ++
        [_]u8{
        0x01, 0x00, // legacy_compression_methods
    } ++ extensions_header;

    mem.writeIntBig(u16, hello_header[3..][0..2], @intCast(u16, hello_header.len - 5 + host.len));
    mem.writeIntBig(u24, hello_header[6..][0..3], @intCast(u24, hello_header.len - 9 + host.len));
    mem.writeIntBig(
        u16,
        hello_header[hello_header.len - extensions_header.len ..][0..2],
        @intCast(u16, extensions_header.len - 2 + host.len),
    );
    mem.writeIntBig(u16, hello_header[hello_header.len - 7 ..][0..2], @intCast(u16, 5 + host.len));
    mem.writeIntBig(u16, hello_header[hello_header.len - 5 ..][0..2], @intCast(u16, 3 + host.len));
    mem.writeIntBig(u16, hello_header[hello_header.len - 2 ..][0..2], @intCast(u16, 0 + host.len));

    {
        var iovecs = [_]std.os.iovec_const{
            .{
                .iov_base = &hello_header,
                .iov_len = hello_header.len,
            },
            .{
                .iov_base = host.ptr,
                .iov_len = host.len,
            },
        };
        try stream.writevAll(&iovecs);
    }

    const client_hello_bytes1 = hello_header[5..];

    var cipher_params: CipherParams = undefined;

    var handshake_buf: [8000]u8 = undefined;
    var len: usize = 0;
    var i: usize = i: {
        const plaintext = handshake_buf[0..5];
        len = try stream.readAtLeast(&handshake_buf, plaintext.len);
        if (len < plaintext.len) return error.EndOfStream;
        const ct = @intToEnum(ContentType, plaintext[0]);
        const frag_len = mem.readIntBig(u16, plaintext[3..][0..2]);
        const end = plaintext.len + frag_len;
        if (end > handshake_buf.len) return error.TlsRecordOverflow;
        if (end > len) {
            len += try stream.readAtLeast(handshake_buf[len..], end - len);
            if (end > len) return error.EndOfStream;
        }
        const frag = handshake_buf[plaintext.len..end];

        switch (ct) {
            .alert => {
                const level = @intToEnum(tls.AlertLevel, frag[0]);
                const desc = @intToEnum(tls.AlertDescription, frag[1]);
                std.debug.print("alert: {s} {s}\n", .{ @tagName(level), @tagName(desc) });
                return error.TlsAlert;
            },
            .handshake => {
                if (frag[0] != @enumToInt(HandshakeType.server_hello)) {
                    return error.TlsUnexpectedMessage;
                }
                const length = mem.readIntBig(u24, frag[1..4]);
                if (4 + length != frag.len) return error.TlsBadLength;
                const hello = frag[4..];
                const legacy_version = mem.readIntBig(u16, hello[0..2]);
                const random = hello[2..34].*;
                if (mem.eql(u8, &random, &tls.hello_retry_request_sequence)) {
                    @panic("TODO handle HelloRetryRequest");
                }
                const legacy_session_id_echo_len = hello[34];
                if (legacy_session_id_echo_len != 0) return error.TlsIllegalParameter;
                const cipher_suite_int = mem.readIntBig(u16, hello[35..37]);
                const cipher_suite_tag = @intToEnum(CipherSuite, cipher_suite_int);
                std.debug.print("server wants cipher suite {any}\n", .{cipher_suite_tag});
                const legacy_compression_method = hello[37];
                _ = legacy_compression_method;
                const extensions_size = mem.readIntBig(u16, hello[38..40]);
                if (40 + extensions_size != hello.len) return error.TlsBadLength;
                var i: usize = 40;
                var supported_version: u16 = 0;
                var opt_x25519_server_pub_key: ?*[32]u8 = null;
                while (i < hello.len) {
                    const et = mem.readIntBig(u16, hello[i..][0..2]);
                    i += 2;
                    const ext_size = mem.readIntBig(u16, hello[i..][0..2]);
                    i += 2;
                    const next_i = i + ext_size;
                    if (next_i > hello.len) return error.TlsBadLength;
                    switch (et) {
                        @enumToInt(tls.ExtensionType.supported_versions) => {
                            if (supported_version != 0) return error.TlsIllegalParameter;
                            supported_version = mem.readIntBig(u16, hello[i..][0..2]);
                        },
                        @enumToInt(tls.ExtensionType.key_share) => {
                            if (opt_x25519_server_pub_key != null) return error.TlsIllegalParameter;
                            const named_group = mem.readIntBig(u16, hello[i..][0..2]);
                            i += 2;
                            switch (named_group) {
                                @enumToInt(tls.NamedGroup.x25519) => {
                                    const key_size = mem.readIntBig(u16, hello[i..][0..2]);
                                    i += 2;
                                    if (key_size != 32) return error.TlsBadLength;
                                    opt_x25519_server_pub_key = hello[i..][0..32];
                                },
                                else => {
                                    std.debug.print("named group: {x}\n", .{named_group});
                                    return error.TlsIllegalParameter;
                                },
                            }
                        },
                        else => {
                            std.debug.print("unexpected extension: {x}\n", .{et});
                        },
                    }
                    i = next_i;
                }
                const x25519_server_pub_key = opt_x25519_server_pub_key orelse
                    return error.TlsIllegalParameter;
                const tls_version = if (supported_version == 0) legacy_version else supported_version;
                switch (tls_version) {
                    @enumToInt(tls.ProtocolVersion.tls_1_2) => {
                        std.debug.print("server wants TLS v1.2\n", .{});
                    },
                    @enumToInt(tls.ProtocolVersion.tls_1_3) => {
                        std.debug.print("server wants TLS v1.3\n", .{});
                    },
                    else => return error.TlsIllegalParameter,
                }

                const shared_key = crypto.dh.X25519.scalarmult(
                    kp.secret_key,
                    x25519_server_pub_key.*,
                ) catch return error.TlsDecryptFailure;

                switch (cipher_suite_tag) {
                    inline .AES_128_GCM_SHA256,
                    .AES_256_GCM_SHA384,
                    .CHACHA20_POLY1305_SHA256,
                    .AEGIS_256_SHA384,
                    .AEGIS_128L_SHA256,
                    => |tag| {
                        const P = std.meta.TagPayloadByName(CipherParams, @tagName(tag));
                        cipher_params = @unionInit(CipherParams, @tagName(tag), .{
                            .handshake_secret = undefined,
                            .master_secret = undefined,
                            .client_handshake_key = undefined,
                            .server_handshake_key = undefined,
                            .client_finished_key = undefined,
                            .server_finished_key = undefined,
                            .client_handshake_iv = undefined,
                            .server_handshake_iv = undefined,
                            .transcript_hash = P.Hash.init(.{}),
                        });
                        const p = &@field(cipher_params, @tagName(tag));
                        p.transcript_hash.update(client_hello_bytes1); // Client Hello part 1
                        p.transcript_hash.update(host); // Client Hello part 2
                        p.transcript_hash.update(frag); // Server Hello
                        const hello_hash = p.transcript_hash.peek();
                        const zeroes = [1]u8{0} ** P.Hash.digest_length;
                        const early_secret = P.Hkdf.extract(&[1]u8{0}, &zeroes);
                        const empty_hash = tls.emptyHash(P.Hash);
                        const hs_derived_secret = hkdfExpandLabel(P.Hkdf, early_secret, "derived", &empty_hash, P.Hash.digest_length);
                        p.handshake_secret = P.Hkdf.extract(&hs_derived_secret, &shared_key);
                        const ap_derived_secret = hkdfExpandLabel(P.Hkdf, p.handshake_secret, "derived", &empty_hash, P.Hash.digest_length);
                        p.master_secret = P.Hkdf.extract(&ap_derived_secret, &zeroes);
                        const client_secret = hkdfExpandLabel(P.Hkdf, p.handshake_secret, "c hs traffic", &hello_hash, P.Hash.digest_length);
                        const server_secret = hkdfExpandLabel(P.Hkdf, p.handshake_secret, "s hs traffic", &hello_hash, P.Hash.digest_length);
                        p.client_finished_key = hkdfExpandLabel(P.Hkdf, client_secret, "finished", "", P.Hmac.key_length);
                        p.server_finished_key = hkdfExpandLabel(P.Hkdf, server_secret, "finished", "", P.Hmac.key_length);
                        p.client_handshake_key = hkdfExpandLabel(P.Hkdf, client_secret, "key", "", P.AEAD.key_length);
                        p.server_handshake_key = hkdfExpandLabel(P.Hkdf, server_secret, "key", "", P.AEAD.key_length);
                        p.client_handshake_iv = hkdfExpandLabel(P.Hkdf, client_secret, "iv", "", P.AEAD.nonce_length);
                        p.server_handshake_iv = hkdfExpandLabel(P.Hkdf, server_secret, "iv", "", P.AEAD.nonce_length);
                        //std.debug.print("shared_key: {}\nhello_hash: {}\nearly_secret: {}\nempty_hash: {}\nderived_secret: {}\nhandshake_secret: {}\n client_secret: {}\n server_secret: {}\nclient_handshake_iv: {}\nserver_handshake_iv: {}\n", .{
                        //    std.fmt.fmtSliceHexLower(&shared_key),
                        //    std.fmt.fmtSliceHexLower(&hello_hash),
                        //    std.fmt.fmtSliceHexLower(&early_secret),
                        //    std.fmt.fmtSliceHexLower(&empty_hash),
                        //    std.fmt.fmtSliceHexLower(&hs_derived_secret),
                        //    std.fmt.fmtSliceHexLower(&p.handshake_secret),
                        //    std.fmt.fmtSliceHexLower(&client_secret),
                        //    std.fmt.fmtSliceHexLower(&server_secret),
                        //    std.fmt.fmtSliceHexLower(&p.client_handshake_iv),
                        //    std.fmt.fmtSliceHexLower(&p.server_handshake_iv),
                        //});
                    },
                    else => {
                        return error.TlsIllegalParameter;
                    },
                }
            },
            else => return error.TlsUnexpectedMessage,
        }
        break :i end;
    };

    var read_seq: u64 = 0;

    while (true) {
        const end_hdr = i + 5;
        if (end_hdr > handshake_buf.len) return error.TlsRecordOverflow;
        if (end_hdr > len) {
            len += try stream.readAtLeast(handshake_buf[len..], end_hdr - len);
            if (end_hdr > len) return error.EndOfStream;
        }
        const ct = @intToEnum(ContentType, handshake_buf[i]);
        i += 1;
        const legacy_version = mem.readIntBig(u16, handshake_buf[i..][0..2]);
        i += 2;
        _ = legacy_version;
        const record_size = mem.readIntBig(u16, handshake_buf[i..][0..2]);
        i += 2;
        const end = i + record_size;
        if (end > handshake_buf.len) return error.TlsRecordOverflow;
        if (end > len) {
            len += try stream.readAtLeast(handshake_buf[len..], end - len);
            if (end > len) return error.EndOfStream;
        }
        switch (ct) {
            .change_cipher_spec => {
                if (record_size != 1) return error.TlsUnexpectedMessage;
                if (handshake_buf[i] != 0x01) return error.TlsUnexpectedMessage;
            },
            .application_data => {
                var cleartext_buf: [8000]u8 = undefined;
                const cleartext = switch (cipher_params) {
                    inline else => |*p| c: {
                        const P = @TypeOf(p.*);
                        const ciphertext_len = record_size - P.AEAD.tag_length;
                        const ciphertext = handshake_buf[i..][0..ciphertext_len];
                        i += ciphertext.len;
                        if (ciphertext.len > cleartext_buf.len) return error.TlsRecordOverflow;
                        const cleartext = cleartext_buf[0..ciphertext.len];
                        const auth_tag = handshake_buf[i..][0..P.AEAD.tag_length].*;
                        const V = @Vector(P.AEAD.nonce_length, u8);
                        const pad = [1]u8{0} ** (P.AEAD.nonce_length - 8);
                        const operand: V = pad ++ @bitCast([8]u8, big(read_seq));
                        read_seq += 1;
                        const nonce = @as(V, p.server_handshake_iv) ^ operand;
                        const ad = handshake_buf[end_hdr - 5 ..][0..5];
                        P.AEAD.decrypt(cleartext, ciphertext, auth_tag, ad, nonce, p.server_handshake_key) catch
                            return error.TlsBadRecordMac;
                        p.transcript_hash.update(cleartext[0 .. cleartext.len - 1]);
                        break :c cleartext;
                    },
                };

                const inner_ct = @intToEnum(ContentType, cleartext[cleartext.len - 1]);
                switch (inner_ct) {
                    .handshake => {
                        var ct_i: usize = 0;
                        while (true) {
                            const handshake_type = cleartext[ct_i];
                            ct_i += 1;
                            const handshake_len = mem.readIntBig(u24, cleartext[ct_i..][0..3]);
                            ct_i += 3;
                            const next_handshake_i = ct_i + handshake_len;
                            if (next_handshake_i > cleartext.len - 1)
                                return error.TlsBadLength;
                            switch (handshake_type) {
                                @enumToInt(HandshakeType.encrypted_extensions) => {
                                    const total_ext_size = mem.readIntBig(u16, cleartext[ct_i..][0..2]);
                                    ct_i += 2;
                                    const end_ext_i = ct_i + total_ext_size;
                                    while (ct_i < end_ext_i) {
                                        const et = mem.readIntBig(u16, cleartext[ct_i..][0..2]);
                                        ct_i += 2;
                                        const ext_size = mem.readIntBig(u16, cleartext[ct_i..][0..2]);
                                        ct_i += 2;
                                        const next_ext_i = ct_i + ext_size;
                                        switch (et) {
                                            @enumToInt(tls.ExtensionType.server_name) => {},
                                            else => {
                                                std.debug.print("encrypted extension: {any}\n", .{
                                                    et,
                                                });
                                            },
                                        }
                                        ct_i = next_ext_i;
                                    }
                                },
                                @enumToInt(HandshakeType.certificate) => {
                                    std.debug.print("cool certificate bro\n", .{});
                                },
                                @enumToInt(HandshakeType.certificate_verify) => {
                                    std.debug.print("the certificate came with a fancy signature\n", .{});
                                },
                                @enumToInt(HandshakeType.finished) => {
                                    // This message is to trick buggy proxies into behaving correctly.
                                    const client_change_cipher_spec_msg = [_]u8{
                                        @enumToInt(ContentType.change_cipher_spec),
                                        0x03, 0x03, // legacy protocol version
                                        0x00, 0x01, // length
                                        0x01,
                                    };
                                    const app_cipher = switch (cipher_params) {
                                        inline else => |*p, tag| c: {
                                            const P = @TypeOf(p.*);
                                            // TODO verify the server's data
                                            const handshake_hash = p.transcript_hash.finalResult();
                                            const verify_data = tls.hmac(P.Hmac, &handshake_hash, p.client_finished_key);
                                            const out_cleartext = [_]u8{
                                                @enumToInt(HandshakeType.finished),
                                                0, 0, verify_data.len, // length
                                            } ++ verify_data ++ [1]u8{@enumToInt(ContentType.handshake)};

                                            const wrapped_len = out_cleartext.len + P.AEAD.tag_length;

                                            var finished_msg = [_]u8{
                                                @enumToInt(ContentType.application_data),
                                                0x03, 0x03, // legacy protocol version
                                                0, wrapped_len, // byte length of encrypted record
                                            } ++ ([1]u8{undefined} ** wrapped_len);

                                            const ad = finished_msg[0..5];
                                            const ciphertext = finished_msg[5..][0..out_cleartext.len];
                                            const auth_tag = finished_msg[finished_msg.len - P.AEAD.tag_length ..];
                                            const nonce = p.client_handshake_iv;
                                            P.AEAD.encrypt(ciphertext, auth_tag, &out_cleartext, ad, nonce, p.client_handshake_key);

                                            const both_msgs = client_change_cipher_spec_msg ++ finished_msg;
                                            try stream.writeAll(&both_msgs);

                                            const client_secret = hkdfExpandLabel(P.Hkdf, p.master_secret, "c ap traffic", &handshake_hash, P.Hash.digest_length);
                                            const server_secret = hkdfExpandLabel(P.Hkdf, p.master_secret, "s ap traffic", &handshake_hash, P.Hash.digest_length);
                                            //std.debug.print("master_secret={}\nclient_secret={}\nserver_secret={}\n", .{
                                            //    std.fmt.fmtSliceHexLower(&p.master_secret),
                                            //    std.fmt.fmtSliceHexLower(&client_secret),
                                            //    std.fmt.fmtSliceHexLower(&server_secret),
                                            //});
                                            break :c @unionInit(ApplicationCipher, @tagName(tag), .{
                                                .client_key = hkdfExpandLabel(P.Hkdf, client_secret, "key", "", P.AEAD.key_length),
                                                .server_key = hkdfExpandLabel(P.Hkdf, server_secret, "key", "", P.AEAD.key_length),
                                                .client_iv = hkdfExpandLabel(P.Hkdf, client_secret, "iv", "", P.AEAD.nonce_length),
                                                .server_iv = hkdfExpandLabel(P.Hkdf, server_secret, "iv", "", P.AEAD.nonce_length),
                                            });
                                        },
                                    };
                                    std.debug.print("remaining bytes: {d}\n", .{len - end});
                                    return .{
                                        .application_cipher = app_cipher,
                                        .read_seq = 0,
                                        .write_seq = 0,
                                        .partially_read_buffer = undefined,
                                        .partially_read_len = 0,
                                        .eof = false,
                                    };
                                },
                                else => {
                                    std.debug.print("handshake type: {d}\n", .{cleartext[0]});
                                    return error.TlsUnexpectedMessage;
                                },
                            }
                            ct_i = next_handshake_i;
                            if (ct_i >= cleartext.len - 1) break;
                        }
                    },
                    else => {
                        std.debug.print("inner content type: {any}\n", .{inner_ct});
                        return error.TlsUnexpectedMessage;
                    },
                }
            },
            else => {
                std.debug.print("content type: {s}\n", .{@tagName(ct)});
                return error.TlsUnexpectedMessage;
            },
        }
        i = end;
    }

    return error.TlsHandshakeFailure;
}

pub fn write(c: *Client, stream: net.Stream, bytes: []const u8) !usize {
    var ciphertext_buf: [tls.max_ciphertext_record_len * 4]u8 = undefined;
    // Due to the trailing inner content type byte in the ciphertext, we need
    // an additional buffer for storing the cleartext into before encrypting.
    var cleartext_buf: [max_ciphertext_len]u8 = undefined;
    var iovecs_buf: [5]std.os.iovec_const = undefined;
    var ciphertext_end: usize = 0;
    var iovec_end: usize = 0;
    var bytes_i: usize = 0;
    // How many bytes are taken up by overhead per record.
    const overhead_len: usize = switch (c.application_cipher) {
        inline else => |*p| l: {
            const P = @TypeOf(p.*);
            const V = @Vector(P.AEAD.nonce_length, u8);
            const overhead_len = tls.ciphertext_record_header_len + P.AEAD.tag_length + 1;
            while (true) {
                const encrypted_content_len = @intCast(u16, @min(
                    @min(bytes.len - bytes_i, max_ciphertext_len - 1),
                    ciphertext_buf.len -
                        tls.ciphertext_record_header_len - P.AEAD.tag_length - ciphertext_end - 1,
                ));
                if (encrypted_content_len == 0) break :l overhead_len;

                mem.copy(u8, &cleartext_buf, bytes[bytes_i..][0..encrypted_content_len]);
                cleartext_buf[encrypted_content_len] = @enumToInt(ContentType.application_data);
                bytes_i += encrypted_content_len;
                const ciphertext_len = encrypted_content_len + 1;
                const cleartext = cleartext_buf[0..ciphertext_len];

                const record_start = ciphertext_end;
                const ad = ciphertext_buf[ciphertext_end..][0..5];
                ad.* =
                    [_]u8{@enumToInt(ContentType.application_data)} ++
                    int2(@enumToInt(tls.ProtocolVersion.tls_1_2)) ++
                    int2(ciphertext_len + P.AEAD.tag_length);
                ciphertext_end += ad.len;
                const ciphertext = ciphertext_buf[ciphertext_end..][0..ciphertext_len];
                ciphertext_end += ciphertext_len;
                const auth_tag = ciphertext_buf[ciphertext_end..][0..P.AEAD.tag_length];
                ciphertext_end += auth_tag.len;
                const pad = [1]u8{0} ** (P.AEAD.nonce_length - 8);
                const operand: V = pad ++ @bitCast([8]u8, big(c.write_seq));
                c.write_seq += 1;
                const nonce = @as(V, p.client_iv) ^ operand;
                P.AEAD.encrypt(ciphertext, auth_tag, cleartext, ad, nonce, p.client_key);
                //std.debug.print("seq: {d} nonce: {} client_key: {} client_iv: {} ad: {} auth_tag: {}\nserver_key: {} server_iv: {}\n", .{
                //    c.write_seq - 1,
                //    std.fmt.fmtSliceHexLower(&nonce),
                //    std.fmt.fmtSliceHexLower(&p.client_key),
                //    std.fmt.fmtSliceHexLower(&p.client_iv),
                //    std.fmt.fmtSliceHexLower(ad),
                //    std.fmt.fmtSliceHexLower(auth_tag),
                //    std.fmt.fmtSliceHexLower(&p.server_key),
                //    std.fmt.fmtSliceHexLower(&p.server_iv),
                //});

                const record = ciphertext_buf[record_start..ciphertext_end];
                iovecs_buf[iovec_end] = .{
                    .iov_base = record.ptr,
                    .iov_len = record.len,
                };
                iovec_end += 1;
            }
        },
    };

    // Ideally we would call writev exactly once here, however, we must ensure
    // that we don't return with a record partially written.
    var i: usize = 0;
    var total_amt: usize = 0;
    while (true) {
        var amt = try stream.writev(iovecs_buf[i..iovec_end]);
        while (amt >= iovecs_buf[i].iov_len) {
            const encrypted_amt = iovecs_buf[i].iov_len;
            total_amt += encrypted_amt - overhead_len;
            amt -= encrypted_amt;
            i += 1;
            // Rely on the property that iovecs delineate records, meaning that
            // if amt equals zero here, we have fortunately found ourselves
            // with a short read that aligns at the record boundary.
            if (i >= iovec_end or amt == 0) return total_amt;
        }
        iovecs_buf[i].iov_base += amt;
        iovecs_buf[i].iov_len -= amt;
    }
}

pub fn writeAll(c: *Client, stream: net.Stream, bytes: []const u8) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        index += try c.write(stream, bytes[index..]);
    }
}

/// Returns number of bytes that have been read, which are now populated inside
/// `buffer`. A return value of zero bytes does not necessarily mean end of
/// stream.
pub fn read(c: *Client, stream: net.Stream, buffer: []u8) !usize {
    const prev_len = c.partially_read_len;
    var in_buf: [max_ciphertext_len * 4]u8 = undefined;
    mem.copy(u8, &in_buf, c.partially_read_buffer[0..prev_len]);

    // Capacity of output buffer, in records, rounded up.
    const buf_cap = (buffer.len +| (max_ciphertext_len - 1)) / max_ciphertext_len;
    const wanted_read_len = buf_cap * (max_ciphertext_len + tls.ciphertext_record_header_len);
    const ask_slice = in_buf[prev_len..@min(wanted_read_len, in_buf.len)];
    const actual_read_len = try stream.read(ask_slice);
    const frag = in_buf[0 .. prev_len + actual_read_len];
    if (frag.len == 0) {
        c.eof = true;
        return 0;
    }
    var in: usize = 0;
    var out: usize = 0;

    while (true) {
        if (in + tls.ciphertext_record_header_len > frag.len) {
            return finishRead(c, frag, in, out);
        }
        const ct = @intToEnum(ContentType, frag[in]);
        in += 1;
        const legacy_version = mem.readIntBig(u16, frag[in..][0..2]);
        in += 2;
        _ = legacy_version;
        const record_size = mem.readIntBig(u16, frag[in..][0..2]);
        in += 2;
        const end = in + record_size;
        if (end > frag.len) {
            if (record_size > max_ciphertext_len) return error.TlsRecordOverflow;
            return finishRead(c, frag, in, out);
        }
        switch (ct) {
            .alert => {
                @panic("TODO handle an alert here");
            },
            .application_data => {
                const cleartext_len = switch (c.application_cipher) {
                    inline else => |*p| c: {
                        const P = @TypeOf(p.*);
                        const V = @Vector(P.AEAD.nonce_length, u8);
                        const ad = frag[in - 5 ..][0..5];
                        const ciphertext_len = record_size - P.AEAD.tag_length;
                        const ciphertext = frag[in..][0..ciphertext_len];
                        in += ciphertext_len;
                        const auth_tag = frag[in..][0..P.AEAD.tag_length].*;
                        const cleartext = buffer[out..][0..ciphertext_len];
                        const pad = [1]u8{0} ** (P.AEAD.nonce_length - 8);
                        const operand: V = pad ++ @bitCast([8]u8, big(c.read_seq));
                        c.read_seq += 1;
                        const nonce: [P.AEAD.nonce_length]u8 = @as(V, p.server_iv) ^ operand;
                        //std.debug.print("seq: {d} nonce: {} server_key: {} server_iv: {}\n", .{
                        //    c.read_seq - 1,
                        //    std.fmt.fmtSliceHexLower(&nonce),
                        //    std.fmt.fmtSliceHexLower(&p.server_key),
                        //    std.fmt.fmtSliceHexLower(&p.server_iv),
                        //});
                        P.AEAD.decrypt(cleartext, ciphertext, auth_tag, ad, nonce, p.server_key) catch
                            return error.TlsBadRecordMac;
                        break :c cleartext.len;
                    },
                };

                const inner_ct = @intToEnum(ContentType, buffer[out + cleartext_len - 1]);
                switch (inner_ct) {
                    .alert => {
                        const level = @intToEnum(tls.AlertLevel, buffer[out]);
                        const desc = @intToEnum(tls.AlertDescription, buffer[out + 1]);
                        if (desc == .close_notify) {
                            c.eof = true;
                            return out;
                        }
                        std.debug.print("alert: {s} {s}\n", .{ @tagName(level), @tagName(desc) });
                        return error.TlsAlert;
                    },
                    .handshake => {
                        std.debug.print("the server wants to keep shaking hands\n", .{});
                    },
                    .application_data => {
                        out += cleartext_len - 1;
                    },
                    else => {
                        std.debug.print("inner content type: {d}\n", .{inner_ct});
                        return error.TlsUnexpectedMessage;
                    },
                }
            },
            else => {
                std.debug.print("unexpected ct: {any}\n", .{ct});
                return error.TlsUnexpectedMessage;
            },
        }
        in = end;
    }
}

fn finishRead(c: *Client, frag: []const u8, in: usize, out: usize) usize {
    const saved_buf = frag[in..];
    mem.copy(u8, &c.partially_read_buffer, saved_buf);
    c.partially_read_len = @intCast(u15, saved_buf.len);
    return out;
}

const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

inline fn big(x: anytype) @TypeOf(x) {
    return switch (native_endian) {
        .Big => x,
        .Little => @byteSwap(x),
    };
}

inline fn int2(x: u16) [2]u8 {
    return .{
        @truncate(u8, x >> 8),
        @truncate(u8, x),
    };
}

/// The priority order here is chosen based on what crypto algorithms Zig has
/// available in the standard library as well as what is faster. Following are
/// a few data points on the relative performance of these algorithms.
///
/// Measurement taken with 0.11.0-dev.810+c2f5848fe
/// on x86_64-linux Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz:
/// zig run .lib/std/crypto/benchmark.zig -OReleaseFast
///       aegis-128l:      15382 MiB/s
///        aegis-256:       9553 MiB/s
///       aes128-gcm:       3721 MiB/s
///       aes256-gcm:       3010 MiB/s
/// chacha20Poly1305:        597 MiB/s
///
/// Measurement taken with 0.11.0-dev.810+c2f5848fe
/// on x86_64-linux Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz:
/// zig run .lib/std/crypto/benchmark.zig -OReleaseFast -mcpu=baseline
///       aegis-128l:        629 MiB/s
/// chacha20Poly1305:        529 MiB/s
///        aegis-256:        461 MiB/s
///       aes128-gcm:        138 MiB/s
///       aes256-gcm:        120 MiB/s
const cipher_suites =
    int2(@enumToInt(tls.CipherSuite.AEGIS_128L_SHA256)) ++
    int2(@enumToInt(tls.CipherSuite.AEGIS_256_SHA384)) ++
    int2(@enumToInt(tls.CipherSuite.AES_128_GCM_SHA256)) ++
    int2(@enumToInt(tls.CipherSuite.AES_256_GCM_SHA384)) ++
    int2(@enumToInt(tls.CipherSuite.CHACHA20_POLY1305_SHA256));

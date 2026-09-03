/*
* ff_record.h
*
* Copyright (c) 2025 debugly <qianlongxu@gmail.com>
*
* This file is part of FSPlayer.
*
* FSPlayer is free software; you can redistribute it and/or
* modify it under the terms of the GNU Lesser General Public
* License as published by the Free Software Foundation; either
* version 3 of the License, or (at your option) any later version.
*
* FSPlayer is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
* Lesser General Public License for more details.
*
* You should have received a copy of the GNU Lesser General Public
* License along with FSPlayer; if not, write to the Free Software
* Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
*/

#include "ff_muxer.h"
#include "ff_ffplay_def.h"
#include "ff_packet_list.h"
#include "libavcodec/avcodec.h"

typedef struct FSMuxer {
    const AVFormatContext *ifmt_ctx;
    AVFormatContext *ofmt_ctx;
    SDL_Thread *write_tid;
    SDL_Thread _write_tid;
    PacketQueue packetq;
    int has_key_video_frame;

    int is_audio_first;
    int is_video_first;
    int64_t audio_start_pts;
    int64_t video_start_pts;

    // 输入流索引到输出流索引的映射
    // stream_mapping[0] = video 输出流索引, stream_mapping[1] = audio 输出流索引
    // -1 表示该流不存在于输出中
    int stream_mapping[2];
    int video_stream;  // 输入视频流索引
    int audio_stream;  // 输入音频流索引

    // 录制文件元数据（拍摄设备、位置等）
    AVDictionary *metadata;
} FSMuxer;

int ff_create_muxer(void **out_ffr, const char *file_name, const AVFormatContext *ifmt_ctx, int audio_stream, int video_stream, const AVCodecContext *video_avctx, const AVCodecContext *audio_avctx, const AVDictionary *metadata)
{
    int r = 0;

    av_log(NULL, AV_LOG_INFO, "[Record] create_muxer: file=%s, video_stream=%d, audio_stream=%d\n",
           file_name ? file_name : "NULL", video_stream, audio_stream);

    if (!file_name || !strlen(file_name)) { // 没有路径
        r = -1;
        av_log(NULL, AV_LOG_ERROR, "recrod filename is invalid\n");
        goto end;
    }

    if (audio_stream == -1 && video_stream == -1) {
        r = -2;
        av_log(NULL, AV_LOG_ERROR, "recrod stream is invalid\n");
        goto end;
    }

    //file_name extension is important!!
    //Could not find tag for codec flv1 in stream #1, codec not currently supported in container
    //vp9 only supported in MP4.
    //Unable to choose an output format for '1747121836247.mkv'; use a standard extension for the filename or specify the format manually.

    FSMuxer *fsr = mallocz(sizeof(FSMuxer));
    fsr->stream_mapping[0] = -1;
    fsr->stream_mapping[1] = -1;
    fsr->video_stream = video_stream;
    fsr->audio_stream = audio_stream;

    // 拷贝 metadata
    if (metadata) {
        av_dict_copy(&fsr->metadata, metadata, 0);
    }

    if (packet_queue_init(&fsr->packetq) < 0){
        r = -3;
        goto end;
    }

    // 初始化一个用于输出的AVFormatContext结构体
    avformat_alloc_output_context2(&fsr->ofmt_ctx, NULL, NULL, file_name);

    if (!fsr->ofmt_ctx) {
        r = -4;
        av_log(NULL, AV_LOG_ERROR, "recrod check your file extention %s\n", file_name);
        goto end;
    }

    int out_stream_idx = 0;
    for (int i = 0; i < ifmt_ctx->nb_streams; i++) {
        if (i == audio_stream || i == video_stream) {
            AVStream *in_stream = ifmt_ctx->streams[i];
            AVCodecParameters *in_codecpar = in_stream->codecpar;

            // 当 find_stream_info=0 时，codecpar 可能不完整（缺少 extradata 等）
            // 解码器上下文 avctx 经过 avcodec_open2 后有完整参数，优先使用
            const AVCodecContext *avctx = NULL;
            if (i == video_stream && video_avctx) {
                avctx = video_avctx;
            } else if (i == audio_stream && audio_avctx) {
                avctx = audio_avctx;
            }

            // 检查 codec_id 是否有效
            enum AVCodecID codec_id = in_codecpar->codec_id;
            if (codec_id == AV_CODEC_ID_NONE && avctx) {
                codec_id = avctx->codec_id;
            }
            if (codec_id == AV_CODEC_ID_NONE) {
                av_log(NULL, AV_LOG_WARNING, "[Record] stream %d has unknown codec, skipping\n", i);
                continue;
            }

            AVStream *out_stream = avformat_new_stream(fsr->ofmt_ctx, NULL);
            if (!out_stream) {
                r = -5;
                av_log(NULL, AV_LOG_ERROR, "[Record] Failed allocating output stream\n");
                goto end;
            }

            // 优先从 avctx 拷贝完整参数（包含 extradata 等），否则从 codecpar 拷贝
            if (avctx && avctx->codec_id != AV_CODEC_ID_NONE) {
                r = avcodec_parameters_from_context(out_stream->codecpar, avctx);
                if (r < 0) {
                    r = -6;
                    av_log(NULL, AV_LOG_ERROR, "[Record] Failed to copy avctx to output stream %d\n", i);
                    goto end;
                }
                av_log(NULL, AV_LOG_INFO, "[Record] stream %d codecpar from avctx (codec=%s, extradata_size=%d)\n",
                       i, avcodec_get_name(avctx->codec_id), avctx->extradata_size);
            } else {
                r = avcodec_parameters_copy(out_stream->codecpar, in_codecpar);
                if (r < 0) {
                    r = -6;
                    av_log(NULL, AV_LOG_ERROR, "[Record] Failed to copy codecpar to output stream %d\n", i);
                    goto end;
                }
                av_log(NULL, AV_LOG_INFO, "[Record] stream %d codecpar from ifmt_ctx (codec=%s, extradata_size=%d)\n",
                       i, avcodec_get_name(in_codecpar->codec_id), in_codecpar->extradata_size);
            }
            if (in_codecpar->codec_id == AV_CODEC_ID_HEVC) {
                out_stream->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');
            } else {
                out_stream->codecpar->codec_tag = 0;
            }
            // 设置start_time
            out_stream->start_time = AV_NOPTS_VALUE;

            // 记录输入流索引到输出流索引的映射
            if (i == video_stream) {
                fsr->stream_mapping[0] = out_stream_idx;
            }
            if (i == audio_stream) {
                fsr->stream_mapping[1] = out_stream_idx;
            }
            out_stream_idx++;
        }
    }

    // 检查是否至少创建了一个有效的输出流
    if (fsr->stream_mapping[0] < 0 && fsr->stream_mapping[1] < 0) {
        r = -2;
        av_log(NULL, AV_LOG_ERROR, "recrod no valid output stream created (video=%d, audio=%d)\n",
               video_stream, audio_stream);
        goto end;
    }
    
    av_dump_format(fsr->ofmt_ctx, 0, file_name, 1);
    fsr->ifmt_ctx = ifmt_ctx;

    av_log(NULL, AV_LOG_INFO, "[Record] create_muxer: success, video_out_idx=%d, audio_out_idx=%d, metadata_count=%d\n",
           fsr->stream_mapping[0], fsr->stream_mapping[1], metadata ? av_dict_count(metadata) : 0);

    if (out_ffr) {
        *out_ffr = (void *)fsr;
    }
    return 0;
end:
    return r;
}

static int do_write_muxer(void *ffr, AVPacket *pkt)
{
    if (!ffr) {
        return 0;
    }
    FSMuxer *fsr = (FSMuxer *)ffr;
    int ret = 0;

    if (pkt == NULL) {
        av_log(NULL, AV_LOG_ERROR, "recrod packet == NULL");
        return -1;
    }

    // 检查输入流索引有效性
    if (pkt->stream_index < 0 || pkt->stream_index >= fsr->ifmt_ctx->nb_streams) {
        av_log(NULL, AV_LOG_WARNING, "recrod packet stream_index %d out of input range, skipping\n", pkt->stream_index);
        av_packet_unref(pkt);
        return 0;
    }

    AVStream *in_stream = fsr->ifmt_ctx->streams[pkt->stream_index];

    // 根据输入流索引查找对应的输出流索引
    int out_idx = -1;
    if (pkt->stream_index == fsr->video_stream) {
        out_idx = fsr->stream_mapping[0];
    } else if (pkt->stream_index == fsr->audio_stream) {
        out_idx = fsr->stream_mapping[1];
    }

    // 不属于录制流的包，跳过
    if (out_idx < 0 || out_idx >= fsr->ofmt_ctx->nb_streams) {
        av_packet_unref(pkt);
        return 0;
    }

    AVStream *out_stream = fsr->ofmt_ctx->streams[out_idx];

    if (pkt->pts != AV_NOPTS_VALUE) {
        // 转换PTS/DTS
        pkt->pts = av_rescale_q_rnd(pkt->pts, in_stream->time_base, out_stream->time_base, (AV_ROUND_NEAR_INF|AV_ROUND_PASS_MINMAX));
    } else {

    }

    pkt->dts = av_rescale_q_rnd(pkt->dts, in_stream->time_base, out_stream->time_base, (AV_ROUND_NEAR_INF|AV_ROUND_PASS_MINMAX));
    pkt->duration = av_rescale_q(pkt->duration, in_stream->time_base, out_stream->time_base);
    pkt->pos = -1;

    if (AVMEDIA_TYPE_AUDIO == in_stream->codecpar->codec_type) {
        if (!fsr->is_audio_first) { // 录制的第一帧
            fsr->is_audio_first = 1;
            fsr->audio_start_pts = pkt->pts;
            pkt->pts = 0;
            pkt->dts = 0;
        } else {
            // 设置了 stream 和 ofmt_ctx 的 start_time都没作用。
            pkt->pts = pkt->pts - fsr->audio_start_pts;
            pkt->dts = pkt->dts - fsr->audio_start_pts;
        }
    } else if (AVMEDIA_TYPE_VIDEO == in_stream->codecpar->codec_type) {
        if (!fsr->is_video_first) { // 录制的第一帧
            fsr->is_video_first = 1;
            fsr->video_start_pts = pkt->pts;
            pkt->pts = 0;
            pkt->dts = 0;
        } else {
            // 设置了 stream 和 ofmt_ctx 的 start_time都没作用。
            pkt->pts = pkt->pts - fsr->video_start_pts;
            pkt->dts = pkt->dts - fsr->video_start_pts;
        }
    }

    // 写入一个AVPacket到输出文件
    if ((ret = av_interleaved_write_frame(fsr->ofmt_ctx, pkt)) < 0) {
        av_log(NULL, AV_LOG_ERROR, "recrod Error muxing packet\n");
    }
    av_packet_unref(pkt);

    return ret;
}

static int write_thread(void *arg)
{
    FSMuxer *fsr = (FSMuxer *)arg;

    av_log(NULL, AV_LOG_INFO, "[Record] write_thread: started\n");

    AVPacket *pkt = av_packet_alloc();

    int r = 0;
    int header_written = 0;
    int video_pkt_count = 0;
    int audio_pkt_count = 0;

    // 打开输出文件
    if (!(fsr->ofmt_ctx->oformat->flags & AVFMT_NOFILE)) {
        if (avio_open(&fsr->ofmt_ctx->pb, fsr->ofmt_ctx->url, AVIO_FLAG_WRITE) < 0) {
            r = -8;
            av_log(NULL, AV_LOG_ERROR, "[Record] write_thread: Could not open output file '%s'\n", fsr->ofmt_ctx->url);
            goto end;
        }
    }

    AVDictionary *opts = NULL;
    // 设置 movflags 为 faststart
    if (strcmp(fsr->ofmt_ctx->oformat->name, "mp4") == 0 || strcmp(fsr->ofmt_ctx->oformat->name, "mov") == 0) {
        av_dict_set(&opts, "movflags", "faststart+use_metadata_tags", 0);
    }

    // 将用户传入的 metadata 写入输出格式上下文
    if (fsr->metadata) {
        av_dict_copy(&fsr->ofmt_ctx->metadata, fsr->metadata, 0);
        av_log(NULL, AV_LOG_INFO, "[Record] write_thread: wrote %d metadata entries\n", av_dict_count(fsr->metadata));
    }

    // 写视频文件头
    if (avformat_write_header(fsr->ofmt_ctx, &opts) < 0) {
        r = -9;
        av_log(NULL, AV_LOG_ERROR, "[Record] write_thread: avformat_write_header failed\n");
        goto end;
    }
    header_written = 1;
    av_log(NULL, AV_LOG_INFO, "[Record] write_thread: header written, format=%s\n", fsr->ofmt_ctx->oformat->name);

    while (fsr->packetq.abort_request == 0) {
        int serial = 0;
        int get_pkt = packet_queue_get(&fsr->packetq, pkt, 1, &serial, NULL);
        if (get_pkt < 0) {
            r = -10;
            break;
        } else if (get_pkt == 0) {
            r = -11;
            break;
        } else {

        }

        // 统计写入的包数
        if (pkt->stream_index == fsr->video_stream) {
            video_pkt_count++;
        } else if (pkt->stream_index == fsr->audio_stream) {
            audio_pkt_count++;
        }

        do_write_muxer(fsr, pkt);
    }
end:
    av_packet_free(&pkt);
    av_dict_free(&opts);

    av_log(NULL, AV_LOG_INFO, "[Record] write_thread: exiting, video_pkts=%d, audio_pkts=%d, header_written=%d\n",
           video_pkt_count, audio_pkt_count, header_written);

    if (fsr->ofmt_ctx != NULL) {
        // 只有 header 成功写入后才写 trailer，否则 av_write_trailer 会崩溃
        if (header_written) {
            r = av_write_trailer(fsr->ofmt_ctx);
            av_log(NULL, AV_LOG_INFO, "[Record] write_thread: trailer written (result=%d)\n", r);
        }
        if (fsr->ofmt_ctx && !(fsr->ofmt_ctx->oformat->flags & AVFMT_NOFILE)) {
            r = avio_close(fsr->ofmt_ctx->pb);
        }
        avformat_free_context(fsr->ofmt_ctx);
        fsr->ofmt_ctx = NULL;
    }
    // 注意：不在这里 destroy packetq，因为解码线程可能还在往队列写数据。
    // packetq 的 destroy 由 ff_destroy_muxer 在解码线程结束后负责。
    av_log(NULL, AV_LOG_INFO, "[Record] write_thread: finished\n");
    return r;
}

int ff_start_muxer(void *ffr)
{
    if (!ffr) {
        return -1;
    }
    int r = 0;
    FSMuxer *fsr = (FSMuxer *)ffr;
    av_log(NULL, AV_LOG_INFO, "[Record] start_muxer: starting write thread\n");
    packet_queue_start(&fsr->packetq);
    fsr->write_tid = SDL_CreateThreadEx(&fsr->_write_tid, write_thread, fsr, "fsmux");
    if (!fsr->write_tid) {
        av_log(NULL, AV_LOG_FATAL, "recrod SDL_CreateThread(): %s\n", SDL_GetError());
        r = -7;
        goto end;
    }
end:
    return r;
}

static int ff_write_muxer(FSMuxer *fsr, struct AVPacket *packet)
{
    if (!fsr) {
        return -1;
    }

    // 检查 muxer 是否已停止，避免向已 abort/destroyed 的队列写入
    if (fsr->packetq.abort_request) {
        return -1;
    }

    AVPacket *pkt = (AVPacket *)av_malloc(sizeof(AVPacket));
    if (!pkt) {
        return -1;
    }
    av_new_packet(pkt, 0);
    av_packet_ref(pkt, packet);

    return packet_queue_put(&fsr->packetq, pkt);
}

int ff_write_audio_muxer(void *ffr, struct AVPacket *packet)
{
    if (!ffr) {
        return -1;
    }
    
    FSMuxer *fsr = (FSMuxer *)ffr;
    
    if (!fsr->has_key_video_frame) {
        return -1;
    }
    
    return ff_write_muxer(fsr, packet);
}

int ff_write_video_muxer(void *ffr, struct AVPacket *packet)
{
    if (!ffr) {
        return -1;
    }

    FSMuxer *fsr = (FSMuxer *)ffr;

    if (!fsr->has_key_video_frame) {
        if (packet->flags & AV_PKT_FLAG_KEY) {
            fsr->has_key_video_frame = 1;
            av_log(NULL, AV_LOG_INFO, "[Record] first video keyframe received, start recording video\n");
        }
    }

    if (!fsr->has_key_video_frame) {
        return -1;
    }

    return ff_write_muxer(fsr, packet);
}

void ff_stop_muxer(void *ffr)
{
    if (!ffr) {
        return;
    }

    FSMuxer *fsr = (FSMuxer *)ffr;
    av_log(NULL, AV_LOG_INFO, "[Record] stop_muxer: aborting packet queue (nb_packets=%d, size=%d)\n",
           fsr->packetq.nb_packets, fsr->packetq.size);
    packet_queue_abort(&fsr->packetq);
    return;
}

int ff_destroy_muxer(void **ffr)
{
    if (!ffr || !*ffr) {
        return -1;
    }
    int r = 0;
    FSMuxer *fsr = (FSMuxer *)*ffr;
    if (fsr) {
        av_log(NULL, AV_LOG_INFO, "[Record] destroy_muxer: waiting for write thread to finish\n");
        if (fsr->write_tid) {
            SDL_WaitThread(fsr->write_tid, &r);
        }
        av_log(NULL, AV_LOG_INFO, "[Record] destroy_muxer: write thread finished (result=%d), destroying packetq\n", r);
        // 在解码线程已结束后 destroy packetq（释放 pkt_list）
        packet_queue_destroy(&fsr->packetq);
        av_dict_free(&fsr->metadata);
        av_freep(ffr);
        av_log(NULL, AV_LOG_INFO, "[Record] destroy_muxer: done\n");
    }
    return r;
}

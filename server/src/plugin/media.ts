import { VideoCamera, Camera, BufferConverter, FFMpegInput, MediaManager, MediaObject, ScryptedDevice, ScryptedInterface, ScryptedMimeTypes, SystemManager, SCRYPTED_MEDIA_SCHEME } from "@scrypted/sdk/types";
import { convert, ensureBuffer } from "../convert";
import { MediaObjectRemote } from "./plugin-api";
import mimeType from 'mime'
import child_process from 'child_process';
import { once } from 'events';
import fs from 'fs';
import tmp from 'tmp';
import os from 'os';
import pathToFfmpeg from 'ffmpeg-for-homebridge';
import { ffmpegLogInitialOutput } from "../media-helpers";

function addBuiltins(console: Console, mediaManager: MediaManager) {
    mediaManager.builtinConverters.push({
        fromMimeType: ScryptedMimeTypes.Url + ';' + ScryptedMimeTypes.AcceptUrlParameter,
        toMimeType: ScryptedMimeTypes.FFmpegInput,
        async convert(data: string | Buffer, fromMimeType: string): Promise<Buffer | string> {
            const args: FFMpegInput = {
                inputArguments: ['-i', data.toString()]
            }

            return Buffer.from(JSON.stringify(args));
        }
    });

    mediaManager.builtinConverters.push({
        fromMimeType: ScryptedMimeTypes.FFmpegInput,
        toMimeType: 'image/jpeg',
        async convert(data: string | Buffer, fromMimeType: string): Promise<Buffer | string> {
            const ffInput: FFMpegInput = JSON.parse(data.toString());

            const args = [
                '-hide_banner',
            ];
            args.push(...ffInput.inputArguments);

            const tmpfile = tmp.fileSync();
            args.push('-y', "-vframes", "1", '-f', 'image2', tmpfile.name);

            const cp = child_process.spawn(await mediaManager.getFFmpegPath(), args);
            ffmpegLogInitialOutput(console, cp);
            cp.on('error', (code) => {
                console.error('ffmpeg error code', code);
            })
            await once(cp, 'exit');
            const ret = fs.readFileSync(tmpfile.name);
            return ret;
        }
    });
}

export class MediaManagerImpl implements MediaManager {
    systemManager: SystemManager;
    builtinConverters: BufferConverter[] = [];

    constructor(systemManager: SystemManager, public console: Console) {
        this.systemManager = systemManager;
        addBuiltins(this.console, this);
    }

    async getFFmpegPath(): Promise<string> {
        // try to get the ffmpeg path as a value of another variable
        // ie, in docker builds:
        //     export SCRYPTED_FFMPEG_PATH_ENV_VARIABLE=SCRYPTED_RASPBIAN_FFMPEG_PATH
        const v = process.env.SCRYPTED_FFMPEG_PATH_ENV_VARIABLE;
        if (v) {
            const f = process.env[v];
            if (f && fs.existsSync(f))
                return f;
        }

        // try to get the ffmpeg path from a variable
        // ie:
        //     export SCRYPTED_FFMPEG_PATH=/usr/local/bin/ffmpeg
        const f = process.env.SCRYPTED_FFMPEG_PATH;
        if (f && fs.existsSync(f))
            return f;

        const defaultPath = os.platform() === 'win32' ? 'ffmpeg.exe' : 'ffmpeg';
        return pathToFfmpeg || defaultPath;
    }

    getConverters(): BufferConverter[] {
        const devices = Object.keys(this.systemManager.getSystemState()).map(id => this.systemManager.getDeviceById(id));
        const converters: BufferConverter[] = Object.values(devices).filter(device => device.interfaces?.includes(ScryptedInterface.BufferConverter))
            .map(device => device as ScryptedDevice & BufferConverter);
        converters.push(...this.builtinConverters);
        return converters;
    }

    ensureMediaObjectRemote(mediaObject: string | MediaObject): MediaObjectRemote {
        if (typeof mediaObject === 'string') {
            const mime = mimeType.lookup(mediaObject);
            return this.createMediaObject(mediaObject, mime);
        }
        return mediaObject as MediaObjectRemote;
    }

    async convertMediaObjectToInsecureLocalUrl(mediaObject: string | MediaObject, toMimeType: string): Promise<string> {
        const intermediate = await convert(this.getConverters(), this.ensureMediaObjectRemote(mediaObject), toMimeType);
        const converted = this.createMediaObject(intermediate.data, intermediate.mimeType);
        const url = await convert(this.getConverters(), converted, ScryptedMimeTypes.InsecureLocalUrl);
        return url.data.toString();
    }

    async convertMediaObjectToBuffer(mediaObject: MediaObject, toMimeType: string): Promise<Buffer> {
        const intermediate = await convert(this.getConverters(), this.ensureMediaObjectRemote(mediaObject), toMimeType);
        return ensureBuffer(intermediate.data);
    }
    async convertMediaObjectToLocalUrl(mediaObject: string | MediaObject, toMimeType: string): Promise<string> {
        const intermediate = await convert(this.getConverters(), this.ensureMediaObjectRemote(mediaObject), toMimeType);
        const converted = this.createMediaObject(intermediate.data, intermediate.mimeType);
        const url = await convert(this.getConverters(), converted, ScryptedMimeTypes.LocalUrl);
        return url.data.toString();
    }
    async convertMediaObjectToUrl(mediaObject: string | MediaObject, toMimeType: string): Promise<string> {
        const intermediate = await convert(this.getConverters(), this.ensureMediaObjectRemote(mediaObject), toMimeType);
        const converted = this.createMediaObject(intermediate.data, intermediate.mimeType);
        const url = await convert(this.getConverters(), converted, ScryptedMimeTypes.Url);
        return url.data.toString();
    }
    createFFmpegMediaObject(ffMpegInput: FFMpegInput): MediaObject {
        const mimeType = ScryptedMimeTypes.FFmpegInput;
        const json = JSON.stringify(ffMpegInput);

        class MediaObjectImpl implements MediaObjectRemote {
            __proxy_props = {
                mimeType,
            }

            mimeType = mimeType;
            async getData(): Promise<Buffer> {
                return Buffer.from(json);
            }
        }
        return new MediaObjectImpl();
    }

    createMediaObject(data: string | Buffer | Promise<string | Buffer>, mimeType?: string): MediaObjectRemote {
        class MediaObjectImpl implements MediaObjectRemote {
            __proxy_props = {
                mimeType,
            }

            mimeType = mimeType;
            async getData(): Promise<Buffer | string> {
                return Promise.resolve(data);
            }
        }
        return new MediaObjectImpl();
    }

    async createMediaObjectFromUrl(data: string, mimeType?: string): Promise<MediaObject> {
        if (!data.startsWith(SCRYPTED_MEDIA_SCHEME))
            return this.createMediaObject(data, mimeType || ScryptedMimeTypes.Url);

        const url = new URL(data.toString());
        const id = url.hostname;
        const path = url.pathname.split('/')[1];
        let mo: MediaObject;
        if (path === ScryptedInterface.VideoCamera) {
            mo = await this.systemManager.getDeviceById<VideoCamera>(id).getVideoStream();
        }
        else if (path === ScryptedInterface.Camera) {
            mo = await this.systemManager.getDeviceById<Camera>(id).takePicture() as any;
        }
        else {
            throw new Error('Unrecognized Scrypted Media interface.')
        }

        return mo;
    }
}

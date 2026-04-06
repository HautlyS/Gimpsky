#!/usr/bin/env node

/**
 * Whisk-GIMP Bridge Server v2
 *
 * Bridges GIMP and the Whisk GUI to the whisk-api.
 * Provides HTTP endpoints for image generation, refinement, captioning, and more.
 *
 * Features:
 * - Session management with cookie validation
 * - Request size limiting
 * - Comprehensive error handling
 * - Automatic session cleanup
 * - Request logging
 */

import http from 'http';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { Whisk, Media, Project } from '/home/workspace/whisk-api/dist/index.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Configuration
const PORT = parseInt(process.env.WHISK_BRIDGE_PORT || '9876', 10);
const OUTPUT_DIR = path.join(__dirname, 'output');
const MAX_REQUEST_SIZE = 50 * 1024 * 1024; // 50MB for image uploads
const SESSION_TTL = 24 * 60 * 60 * 1000; // 24 hours
const CLEANUP_INTERVAL = 60 * 60 * 1000; // 1 hour

// Ensure output directory exists
if (!fs.existsSync(OUTPUT_DIR)) {
    fs.mkdirSync(OUTPUT_DIR, { recursive: true });
}

// Session storage
const sessions = new Map();
let sessionIdCounter = 0;

// Logging
function log(level, message, meta = {}) {
    const timestamp = new Date().toISOString();
    const entry = {
        timestamp,
        level,
        message,
        ...meta
    };
    console.log(JSON.stringify(entry));
}

function logRequest(req, statusCode, duration) {
    log('info', `${req.method} ${req.url} ${statusCode}`, {
        method: req.method,
        url: req.url,
        statusCode,
        durationMs: duration
    });
}

// Response helpers
function jsonResponse(res, statusCode, data) {
    const body = JSON.stringify(data);
    res.writeHead(statusCode, {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization',
        'Access-Control-Max-Age': '86400'
    });
    res.end(body);
}

function errorResponse(res, statusCode, message, code = null) {
    return jsonResponse(res, statusCode, {
        error: message,
        code: code || 'UNKNOWN_ERROR',
        timestamp: new Date().toISOString()
    });
}

// Body parser with size limit
async function parseBody(req) {
    return new Promise((resolve, reject) => {
        let body = '';
        let size = 0;

        req.on('data', chunk => {
            size += chunk.length;
            if (size > MAX_REQUEST_SIZE) {
                req.destroy();
                reject(new Error('Request body too large'));
                return;
            }
            body += chunk;
        });

        req.on('end', () => {
            try {
                resolve(body ? JSON.parse(body) : {});
            } catch (e) {
                reject(new Error('Invalid JSON in request body'));
            }
        });

        req.on('error', reject);
        req.on('aborted', () => reject(new Error('Request aborted')));
    });
}

// Session management
function createSession(whisk) {
    const sessionId = `session_${++sessionIdCounter}_${Date.now()}`;
    sessions.set(sessionId, {
        whisk,
        createdAt: Date.now(),
        lastAccessed: Date.now(),
        project: null,
        requestCount: 0
    });
    return sessionId;
}

function getSession(sessionId) {
    const session = sessions.get(sessionId);
    if (!session) return null;

    // Check TTL
    if (Date.now() - session.createdAt > SESSION_TTL) {
        sessions.delete(sessionId);
        return null;
    }

    session.lastAccessed = Date.now();
    session.requestCount++;
    return session;
}

function cleanupExpiredSessions() {
    const now = Date.now();
    let cleaned = 0;
    for (const [id, session] of sessions.entries()) {
        if (now - session.lastAccessed > SESSION_TTL) {
            sessions.delete(id);
            cleaned++;
        }
    }
    if (cleaned > 0) {
        log('info', `Cleaned up ${cleaned} expired sessions`);
    }
}

// Run cleanup periodically
setInterval(cleanupExpiredSessions, CLEANUP_INTERVAL);

// Get or create Whisk instance from cookie
function getOrCreateWhisk(cookie) {
    if (!cookie || typeof cookie !== 'string' || !cookie.trim()) {
        throw new Error('Valid cookie is required');
    }
    return new Whisk(cookie.trim());
}

// Route handlers
const routes = {
    // GET /health - Health check
    async health(req, res) {
        return jsonResponse(res, 200, {
            status: 'ok',
            port: PORT,
            version: '2.0.0',
            whiskApiVersion: '4.0.1',
            uptime: process.uptime(),
            activeSessions: sessions.size,
            timestamp: new Date().toISOString()
        });
    },

    // POST /init - Initialize session with cookie
    async init(req, res) {
        const body = await parseBody(req);
        const { cookie } = body;

        if (!cookie || typeof cookie !== 'string' || !cookie.trim()) {
            return errorResponse(res, 400, 'Cookie is required', 'MISSING_COOKIE');
        }

        try {
            const whisk = getOrCreateWhisk(cookie);
            await whisk.account.refresh();

            const sessionId = createSession(whisk);

            return jsonResponse(res, 200, {
                sessionId,
                account: whisk.account.toString(),
                message: 'Session created successfully'
            });
        } catch (e) {
            log('error', 'Session initialization failed', { error: e.message });
            return errorResponse(res, 401, `Invalid cookie or authentication failed: ${e.message}`, 'AUTH_FAILED');
        }
    },

    // POST /project - Create a new project
    async project(req, res) {
        const body = await parseBody(req);
        const { cookie, sessionId, projectName } = body;

        // Support both cookie and session-based auth
        let whisk;
        if (sessionId) {
            const session = getSession(sessionId);
            if (!session) {
                return errorResponse(res, 401, 'Invalid or expired session', 'INVALID_SESSION');
            }
            whisk = session.whisk;
        } else if (cookie) {
            whisk = getOrCreateWhisk(cookie);
        } else {
            return errorResponse(res, 401, 'Session ID or cookie is required', 'MISSING_AUTH');
        }

        try {
            const project = await whisk.newProject(projectName || 'GIMP Whisk Project');

            // Store project in session if using session auth
            if (sessionId) {
                const session = getSession(sessionId);
                if (session) session.project = project;
            }

            return jsonResponse(res, 200, {
                projectId: project.projectId,
                projectName: projectName || 'GIMP Whisk Project'
            });
        } catch (e) {
            log('error', 'Project creation failed', { error: e.message });
            return errorResponse(res, 500, `Failed to create project: ${e.message}`, 'PROJECT_FAILED');
        }
    },

    // POST /generate - Generate image from text prompt
    async generate(req, res) {
        const body = await parseBody(req);
        const { cookie, sessionId, prompt, aspectRatio = 'IMAGE_ASPECT_RATIO_LANDSCAPE', model = 'IMAGEN_3_5', seed = 0 } = body;

        let whisk;
        if (sessionId) {
            const session = getSession(sessionId);
            if (!session) return errorResponse(res, 401, 'Invalid or expired session', 'INVALID_SESSION');
            whisk = session.whisk;
        } else if (cookie) {
            whisk = getOrCreateWhisk(cookie);
        } else {
            return errorResponse(res, 401, 'Session ID or cookie is required', 'MISSING_AUTH');
        }

        if (!prompt || typeof prompt !== 'string' || !prompt.trim()) {
            return errorResponse(res, 400, 'Prompt is required', 'MISSING_PROMPT');
        }

        try {
            const images = await whisk.generateImage({
                prompt: prompt.trim(),
                aspectRatio,
                model,
                seed: parseInt(seed, 10) || 0
            });

            const results = [];
            for (const media of images) {
                const savedPath = media.save(OUTPUT_DIR);
                results.push({
                    mediaGenerationId: media.mediaGenerationId,
                    savedPath,
                    base64: media.encodedMedia,
                    prompt: media.prompt,
                    seed: media.seed,
                    aspectRatio: media.aspectRatio,
                    model: media.model
                });
            }

            log('info', `Generated ${results.length} image(s)`, { prompt: prompt.substring(0, 50) });
            return jsonResponse(res, 200, { images: results });
        } catch (e) {
            log('error', 'Image generation failed', { error: e.message, prompt: prompt.substring(0, 50) });
            return errorResponse(res, 500, `Failed to generate image: ${e.message}`, 'GENERATION_FAILED');
        }
    },

    // POST /refine - Refine/edit an image
    async refine(req, res) {
        const body = await parseBody(req);
        const { cookie, sessionId, mediaGenerationId, editPrompt } = body;

        let whisk;
        if (sessionId) {
            const session = getSession(sessionId);
            if (!session) return errorResponse(res, 401, 'Invalid or expired session', 'INVALID_SESSION');
            whisk = session.whisk;
        } else if (cookie) {
            whisk = getOrCreateWhisk(cookie);
        } else {
            return errorResponse(res, 401, 'Session ID or cookie is required', 'MISSING_AUTH');
        }

        if (!mediaGenerationId) {
            return errorResponse(res, 400, 'mediaGenerationId is required', 'MISSING_MEDIA_ID');
        }
        if (!editPrompt || typeof editPrompt !== 'string' || !editPrompt.trim()) {
            return errorResponse(res, 400, 'Edit prompt is required', 'MISSING_EDIT_PROMPT');
        }

        try {
            const media = await Whisk.getMedia(mediaGenerationId, whisk.account);
            const refinedMedia = await media.refine(editPrompt.trim());
            const savedPath = refinedMedia.save(OUTPUT_DIR);

            return jsonResponse(res, 200, {
                mediaGenerationId: refinedMedia.mediaGenerationId,
                savedPath,
                base64: refinedMedia.encodedMedia,
                prompt: refinedMedia.prompt,
                refined: true
            });
        } catch (e) {
            log('error', 'Image refinement failed', { error: e.message });
            return errorResponse(res, 500, `Failed to refine image: ${e.message}`, 'REFINEMENT_FAILED');
        }
    },

    // POST /caption - Generate caption from image
    async caption(req, res) {
        const body = await parseBody(req);
        const { cookie, sessionId, base64Image, count = 3 } = body;

        let whisk;
        if (sessionId) {
            const session = getSession(sessionId);
            if (!session) return errorResponse(res, 401, 'Invalid or expired session', 'INVALID_SESSION');
            whisk = session.whisk;
        } else if (cookie) {
            whisk = getOrCreateWhisk(cookie);
        } else {
            return errorResponse(res, 401, 'Session ID or cookie is required', 'MISSING_AUTH');
        }

        if (!base64Image) {
            return errorResponse(res, 400, 'base64Image is required', 'MISSING_IMAGE');
        }

        const captionCount = Math.min(Math.max(parseInt(count, 10) || 3, 1), 8);

        try {
            const captions = await Whisk.generateCaption(base64Image, whisk.account, captionCount);
            return jsonResponse(res, 200, { captions });
        } catch (e) {
            log('error', 'Caption generation failed', { error: e.message });
            return errorResponse(res, 500, `Failed to generate caption: ${e.message}`, 'CAPTION_FAILED');
        }
    },

    // POST /animate - Animate image to video
    async animate(req, res) {
        const body = await parseBody(req);
        const { cookie, sessionId, mediaGenerationId, videoScript, model = 'VEO_3_1' } = body;

        let whisk;
        if (sessionId) {
            const session = getSession(sessionId);
            if (!session) return errorResponse(res, 401, 'Invalid or expired session', 'INVALID_SESSION');
            whisk = session.whisk;
        } else if (cookie) {
            whisk = getOrCreateWhisk(cookie);
        } else {
            return errorResponse(res, 401, 'Session ID or cookie is required', 'MISSING_AUTH');
        }

        if (!mediaGenerationId) {
            return errorResponse(res, 400, 'mediaGenerationId is required', 'MISSING_MEDIA_ID');
        }
        if (!videoScript || typeof videoScript !== 'string' || !videoScript.trim()) {
            return errorResponse(res, 400, 'Video script is required', 'MISSING_SCRIPT');
        }

        try {
            const media = await Whisk.getMedia(mediaGenerationId, whisk.account);
            const videoMedia = await media.animate(videoScript.trim(), model);
            const savedPath = videoMedia.save(OUTPUT_DIR);

            return jsonResponse(res, 200, {
                mediaGenerationId: videoMedia.mediaGenerationId,
                savedPath,
                base64: videoMedia.encodedMedia,
                mediaType: 'VIDEO',
                prompt: videoMedia.prompt
            });
        } catch (e) {
            log('error', 'Animation failed', { error: e.message });
            return errorResponse(res, 500, `Failed to animate image: ${e.message}`, 'ANIMATION_FAILED');
        }
    },

    // POST /fetch - Fetch existing media by ID
    async fetch(req, res) {
        const body = await parseBody(req);
        const { cookie, sessionId, mediaGenerationId } = body;

        let whisk;
        if (sessionId) {
            const session = getSession(sessionId);
            if (!session) return errorResponse(res, 401, 'Invalid or expired session', 'INVALID_SESSION');
            whisk = session.whisk;
        } else if (cookie) {
            whisk = getOrCreateWhisk(cookie);
        } else {
            return errorResponse(res, 401, 'Session ID or cookie is required', 'MISSING_AUTH');
        }

        if (!mediaGenerationId) {
            return errorResponse(res, 400, 'mediaGenerationId is required', 'MISSING_MEDIA_ID');
        }

        try {
            const media = await Whisk.getMedia(mediaGenerationId, whisk.account);
            const savedPath = media.save(OUTPUT_DIR);

            return jsonResponse(res, 200, {
                mediaGenerationId: media.mediaGenerationId,
                savedPath,
                base64: media.encodedMedia,
                prompt: media.prompt,
                mediaType: media.mediaType,
                aspectRatio: media.aspectRatio,
                seed: media.seed,
                model: media.model
            });
        } catch (e) {
            log('error', 'Fetch failed', { error: e.message, mediaId: mediaGenerationId });
            return errorResponse(res, 500, `Failed to fetch media: ${e.message}`, 'FETCH_FAILED');
        }
    },

    // POST /delete - Delete media
    async delete(req, res) {
        const body = await parseBody(req);
        const { cookie, sessionId, mediaGenerationId } = body;

        let whisk;
        if (sessionId) {
            const session = getSession(sessionId);
            if (!session) return errorResponse(res, 401, 'Invalid or expired session', 'INVALID_SESSION');
            whisk = session.whisk;
        } else if (cookie) {
            whisk = getOrCreateWhisk(cookie);
        } else {
            return errorResponse(res, 401, 'Session ID or cookie is required', 'MISSING_AUTH');
        }

        if (!mediaGenerationId) {
            return errorResponse(res, 400, 'mediaGenerationId is required', 'MISSING_MEDIA_ID');
        }

        try {
            await Whisk.deleteMedia(mediaGenerationId, whisk.account);
            return jsonResponse(res, 200, { success: true, message: 'Media deleted successfully' });
        } catch (e) {
            log('error', 'Delete failed', { error: e.message, mediaId: mediaGenerationId });
            return errorResponse(res, 500, `Failed to delete media: ${e.message}`, 'DELETE_FAILED');
        }
    },

    // POST /upload - Upload image as reference
    async upload(req, res) {
        const body = await parseBody(req);
        const { cookie, sessionId, base64Image, category, caption, projectId } = body;

        let whisk;
        if (sessionId) {
            const session = getSession(sessionId);
            if (!session) return errorResponse(res, 401, 'Invalid or expired session', 'INVALID_SESSION');
            whisk = session.whisk;
        } else if (cookie) {
            whisk = getOrCreateWhisk(cookie);
        } else {
            return errorResponse(res, 401, 'Session ID or cookie is required', 'MISSING_AUTH');
        }

        if (!base64Image) {
            return errorResponse(res, 400, 'base64Image is required', 'MISSING_IMAGE');
        }
        if (!category) {
            return errorResponse(res, 400, 'category is required (SUBJECT, SCENE, or STYLE)', 'MISSING_CATEGORY');
        }
        if (!projectId) {
            return errorResponse(res, 400, 'projectId is required', 'MISSING_PROJECT_ID');
        }

        try {
            const uploadMediaId = await Whisk.uploadImage(
                base64Image,
                caption || 'Reference image',
                category,
                projectId,
                whisk.account
            );

            return jsonResponse(res, 200, {
                uploadMediaGenerationId: uploadMediaId
            });
        } catch (e) {
            log('error', 'Upload failed', { error: e.message });
            return errorResponse(res, 500, `Failed to upload image: ${e.message}`, 'UPLOAD_FAILED');
        }
    },

    // POST /generate-with-references - Generate with subject/scene/style references
    async generateWithReferences(req, res) {
        const body = await parseBody(req);
        const { cookie, sessionId, prompt, aspectRatio = 'IMAGE_ASPECT_RATIO_LANDSCAPE', model = 'IMAGEN_3_5', seed = 0 } = body;

        let whisk;
        let session = null;
        if (sessionId) {
            session = getSession(sessionId);
            if (!session) return errorResponse(res, 401, 'Invalid or expired session', 'INVALID_SESSION');
            whisk = session.whisk;
        } else if (cookie) {
            whisk = getOrCreateWhisk(cookie);
        } else {
            return errorResponse(res, 401, 'Session ID or cookie is required', 'MISSING_AUTH');
        }

        if (!prompt || typeof prompt !== 'string' || !prompt.trim()) {
            return errorResponse(res, 400, 'Prompt is required', 'MISSING_PROMPT');
        }

        try {
            // Use existing project or create one
            let project = session?.project;
            if (!project) {
                project = await whisk.newProject('GIMP Whisk Project');
                if (session) session.project = project;
            }

            // Add references if provided
            const { subjects, scenes, styles } = body;

            if (subjects && Array.isArray(subjects)) {
                for (const sub of subjects) {
                    if (sub.base64) {
                        await project.addSubject({ base64: sub.base64 });
                    }
                }
            }

            if (scenes && Array.isArray(scenes)) {
                for (const scene of scenes) {
                    if (scene.base64) {
                        await project.addScene({ base64: scene.base64 });
                    }
                }
            }

            if (styles && Array.isArray(styles)) {
                for (const style of styles) {
                    if (style.base64) {
                        await project.addStyle({ base64: style.base64 });
                    }
                }
            }

            const media = await project.generateImageWithReferences({
                prompt: prompt.trim(),
                aspectRatio,
                model,
                seed: parseInt(seed, 10) || 0
            });

            const savedPath = media.save(OUTPUT_DIR);

            return jsonResponse(res, 200, {
                mediaGenerationId: media.mediaGenerationId,
                savedPath,
                base64: media.encodedMedia,
                prompt: media.prompt,
                seed: media.seed,
                aspectRatio: media.aspectRatio
            });
        } catch (e) {
            log('error', 'Generation with references failed', { error: e.message });
            return errorResponse(res, 500, `Failed to generate image with references: ${e.message}`, 'REFERENCE_GENERATION_FAILED');
        }
    },

    // GET /list-outputs - List output files
    async listOutputs(req, res) {
        try {
            if (!fs.existsSync(OUTPUT_DIR)) {
                return jsonResponse(res, 200, { files: [] });
            }

            const files = fs.readdirSync(OUTPUT_DIR)
                .filter(f => /\.(png|jpg|jpeg|webp|mp4|gif)$/i.test(f))
                .map(f => {
                    const stats = fs.statSync(path.join(OUTPUT_DIR, f));
                    return {
                        filename: f,
                        path: path.join(OUTPUT_DIR, f),
                        size: stats.size,
                        modified: stats.mtime.toISOString()
                    };
                })
                .sort((a, b) => new Date(b.modified) - new Date(a.modified));

            return jsonResponse(res, 200, { files, count: files.length });
        } catch (e) {
            return errorResponse(res, 500, `Failed to list outputs: ${e.message}`, 'LIST_FAILED');
        }
    },

    // GET /output/:filename - Serve output file
    async output(req, res, filename) {
        try {
            const filepath = path.join(OUTPUT_DIR, filename);

            // Prevent directory traversal
            if (!filepath.startsWith(OUTPUT_DIR)) {
                return errorResponse(res, 403, 'Access denied', 'FORBIDDEN');
            }

            if (!fs.existsSync(filepath)) {
                return errorResponse(res, 404, 'File not found', 'NOT_FOUND');
            }

            const ext = path.extname(filepath).toLowerCase();
            const mimeTypes = {
                '.png': 'image/png',
                '.jpg': 'image/jpeg',
                '.jpeg': 'image/jpeg',
                '.webp': 'image/webp',
                '.mp4': 'video/mp4',
                '.gif': 'image/gif'
            };

            const stat = fs.statSync(filepath);
            res.writeHead(200, {
                'Content-Type': mimeTypes[ext] || 'application/octet-stream',
                'Content-Length': stat.size,
                'Cache-Control': 'public, max-age=3600',
                'Access-Control-Allow-Origin': '*'
            });

            fs.createReadStream(filepath).pipe(res);
        } catch (e) {
            return errorResponse(res, 500, `Failed to serve file: ${e.message}`, 'SERVE_FAILED');
        }
    }
};

// Request handler
const server = http.createServer(async (req, res) => {
    const startTime = Date.now();

    // Handle CORS preflight
    if (req.method === 'OPTIONS') {
        res.writeHead(200, {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Content-Type, Authorization',
            'Access-Control-Max-Age': '86400'
        });
        res.end();
        logRequest(req, 200, Date.now() - startTime);
        return;
    }

    try {
        const url = new URL(req.url, `http://localhost:${PORT}`);
        const pathname = url.pathname;

        // Route matching
        if (pathname === '/health' && req.method === 'GET') {
            await routes.health(req, res);
        } else if (pathname === '/init' && req.method === 'POST') {
            await routes.init(req, res);
        } else if (pathname === '/project' && req.method === 'POST') {
            await routes.project(req, res);
        } else if (pathname === '/generate' && req.method === 'POST') {
            await routes.generate(req, res);
        } else if (pathname === '/refine' && req.method === 'POST') {
            await routes.refine(req, res);
        } else if (pathname === '/caption' && req.method === 'POST') {
            await routes.caption(req, res);
        } else if (pathname === '/animate' && req.method === 'POST') {
            await routes.animate(req, res);
        } else if (pathname === '/fetch' && req.method === 'POST') {
            await routes.fetch(req, res);
        } else if (pathname === '/delete' && req.method === 'POST') {
            await routes.delete(req, res);
        } else if (pathname === '/upload' && req.method === 'POST') {
            await routes.upload(req, res);
        } else if (pathname === '/generate-with-references' && req.method === 'POST') {
            await routes.generateWithReferences(req, res);
        } else if (pathname === '/list-outputs' && req.method === 'GET') {
            await routes.listOutputs(req, res);
        } else if (pathname.startsWith('/output/') && req.method === 'GET') {
            const filename = pathname.substring('/output/'.length);
            await routes.output(req, res, filename);
        } else {
            errorResponse(res, 404, `Unknown endpoint: ${pathname}`, 'NOT_FOUND');
        }

        logRequest(req, res.statusCode || 200, Date.now() - startTime);
    } catch (e) {
        const statusCode = e.message === 'Request body too large' ? 413 :
                          e.message === 'Invalid JSON in request body' ? 400 : 500;
        const errorCode = e.message === 'Request body too large' ? 'PAYLOAD_TOO_LARGE' :
                         e.message === 'Invalid JSON in request body' ? 'INVALID_JSON' : 'INTERNAL_ERROR';

        if (statusCode === 500) {
            log('error', `Unhandled error: ${e.message}`, { stack: e.stack });
        }

        if (!res.headersSent) {
            errorResponse(res, statusCode, e.message || 'Internal server error', errorCode);
        }

        logRequest(req, statusCode, Date.now() - startTime);
    }
});

// Start server
server.listen(PORT, '127.0.0.1', () => {
    console.log(JSON.stringify({
        timestamp: new Date().toISOString(),
        level: 'info',
        message: `Whisk-GIMP Bridge Server v2.0.0 started`,
        port: PORT,
        bindAddress: '127.0.0.1',
        outputDir: OUTPUT_DIR,
        maxRequestSize: `${MAX_REQUEST_SIZE / (1024 * 1024)}MB`
    }));
});

// Graceful shutdown
function shutdown(signal) {
    console.log(JSON.stringify({
        timestamp: new Date().toISOString(),
        level: 'info',
        message: `Received ${signal}, shutting down gracefully...`
    }));

    server.close(() => {
        console.log(JSON.stringify({
            timestamp: new Date().toISOString(),
            level: 'info',
            message: 'Server closed'
        }));
        process.exit(0);
    });

    // Force close after 10 seconds
    setTimeout(() => {
        console.error('Forced shutdown after timeout');
        process.exit(1);
    }, 10000);
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));

// Handle uncaught errors
process.on('uncaughtException', (e) => {
    console.error(JSON.stringify({
        timestamp: new Date().toISOString(),
        level: 'error',
        message: 'Uncaught exception',
        error: e.message,
        stack: e.stack
    }));
});

process.on('unhandledRejection', (reason) => {
    console.error(JSON.stringify({
        timestamp: new Date().toISOString(),
        level: 'error',
        message: 'Unhandled promise rejection',
        reason: String(reason)
    }));
});

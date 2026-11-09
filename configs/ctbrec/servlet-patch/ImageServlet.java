/*
 * Decompiled with CFR 0.152.
 * 
 * Could not load the following classes:
 *  ctbrec.Config
 *  ctbrec.Model
 *  ctbrec.io.NetworkDiagnostics
 *  ctbrec.recorder.Recorder
 *  ctbrec.recorder.server.AbstractCtbrecServlet
 *  ctbrec.recorder.server.AbstractCtbrecServlet$PayloadTooLargeException
 *  ctbrec.recorder.server.ImageServlet$1
 *  ctbrec.sites.Site
 *  javax.servlet.http.HttpServletRequest
 *  javax.servlet.http.HttpServletResponse
 *  lombok.Generated
 *  okhttp3.OkHttpClient
 *  okhttp3.OkHttpClient$Builder
 *  okhttp3.Request
 *  okhttp3.Request$Builder
 *  okhttp3.Response
 *  org.slf4j.Logger
 *  org.slf4j.LoggerFactory
 */
package ctbrec.recorder.server;

import ctbrec.Config;
import ctbrec.Model;
import ctbrec.PortraitUrlProvider;
import ctbrec.image.PortraitStore;
import ctbrec.io.NetworkDiagnostics;
import ctbrec.recorder.Recorder;
import ctbrec.recorder.server.AbstractCtbrecServlet;
import ctbrec.recorder.server.ImageServlet;
import ctbrec.sites.Site;
import java.awt.Graphics2D;
import java.awt.Image;
import java.awt.image.BufferedImage;
import java.awt.image.RenderedImage;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.SecureRandom;
import java.util.Iterator;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import javax.imageio.ImageIO;
import javax.imageio.ImageReader;
import javax.imageio.stream.ImageInputStream;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public class ImageServlet
extends AbstractCtbrecServlet {
    private static final Logger log = LoggerFactory.getLogger(ImageServlet.class);
    private static final int MAX_IMAGE_BYTES = 0xA00000;
    private static final long MAX_IMAGE_PIXELS = 25000000L;
    public static final String BASE_URL = "/image";
    private static final Pattern URL_PATTERN_PORTRAIT_BY_ID = Pattern.compile("/image/portrait/([0-9a-fA-F]{8}\\b-[0-9a-fA-F]{4}\\b-[0-9a-fA-F]{4}\\b-[0-9a-fA-F]{4}\\b-[0-9a-fA-F]{12})");
    private static final Pattern URL_PATTERN_PORTRAIT_BY_URL = Pattern.compile("/image/portrait/url/(.*)");
    private static final Pattern URL_PATTERN_PORTRAIT_FETCH = Pattern.compile("/image/portrait/fetch/(.*)");
    private static final Pattern URL_PATTERN_RECORDING_IMAGE = Pattern.compile("/image/recording/(.*)");
    private final PortraitStore portraitStore;
    private final Config config;
    private final Recorder recorder;
    private final OkHttpClient lenientHttpClient;

    public ImageServlet(PortraitStore portraitStore, Config config, Recorder recorder) {
        this.portraitStore = portraitStore;
        this.config = config;
        this.recorder = recorder;
        this.lenientHttpClient = ImageServlet.createLenientHttpClient(config);
    }

    private static OkHttpClient createLenientHttpClient(Config config) {
        try {
            X509TrustManager trustAllCerts = new X509TrustManager() {
                @Override
                public void checkClientTrusted(java.security.cert.X509Certificate[] chain, String authType) {
                }

                @Override
                public void checkServerTrusted(java.security.cert.X509Certificate[] chain, String authType) {
                }

                @Override
                public java.security.cert.X509Certificate[] getAcceptedIssuers() {
                    return new java.security.cert.X509Certificate[0];
                }
            };
            SSLContext sslContext = SSLContext.getInstance("TLS");
            sslContext.init(null, new TrustManager[]{trustAllCerts}, new SecureRandom());
            return new OkHttpClient.Builder().sslSocketFactory(sslContext.getSocketFactory(), trustAllCerts).hostnameVerifier((hostname, session) -> true).connectTimeout((long)config.getSettings().httpTimeout, TimeUnit.MILLISECONDS).readTimeout((long)config.getSettings().httpTimeout, TimeUnit.MILLISECONDS).eventListenerFactory(NetworkDiagnostics.eventListenerFactory()).build();
        }
        catch (Exception e) {
            log.warn("Failed to create lenient HTTP client, falling back to default", (Throwable)e);
            return new OkHttpClient.Builder().connectTimeout((long)config.getSettings().httpTimeout, TimeUnit.MILLISECONDS).readTimeout((long)config.getSettings().httpTimeout, TimeUnit.MILLISECONDS).eventListenerFactory(NetworkDiagnostics.eventListenerFactory()).build();
        }
    }

    protected void doGet(HttpServletRequest req, HttpServletResponse resp) {
        String requestURI = req.getRequestURI().substring(req.getContextPath().length());
        try {
            boolean authenticated = this.checkAuthentication(req, "");
            if (!authenticated) {
                this.sendResponse(resp, 401, "{\"status\": \"error\", \"msg\": \"HMAC does not match\"}");
                return;
            }
            Matcher m = URL_PATTERN_PORTRAIT_BY_ID.matcher(requestURI);
            if (m.matches()) {
                String portraitId = m.group(1);
                this.servePortrait(resp, portraitId);
            } else {
                m = URL_PATTERN_PORTRAIT_FETCH.matcher(requestURI);
                if (m.matches()) {
                    String modelUrl = URLDecoder.decode(m.group(1), StandardCharsets.UTF_8);
                    boolean previewOnly = "true".equalsIgnoreCase(req.getParameter("preview"));
                    this.fetchAndServePreview(resp, modelUrl, previewOnly);
                } else {
                    m = URL_PATTERN_PORTRAIT_BY_URL.matcher(requestURI);
                    if (m.matches()) {
                        String modelUrl = URLDecoder.decode(m.group(1), StandardCharsets.UTF_8);
                        String portraitId = (String)this.config.getSettings().modelPortraits.get(modelUrl);
                        this.servePortrait(resp, portraitId);
                    } else {
                        m = URL_PATTERN_RECORDING_IMAGE.matcher(requestURI);
                        if (m.matches()) {
                            String filename = m.group(1);
                            this.serveRecordingImage(resp, filename);
                        }
                    }
                }
            }
        }
        catch (Exception e) {
            log.error("Internal Server Error", (Throwable)e);
            this.sendResponse(resp, 500, "Internal Server Error");
        }
    }

    private void servePortrait(HttpServletResponse resp, String portraitId) throws IOException {
        Optional<byte[]> imageData = this.portraitStore.loadModelPortraitById(portraitId);
        if (imageData.isPresent()) {
            resp.setStatus(200);
            resp.setContentType("image/jpeg");
            resp.setHeader("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0");
            byte[] b = imageData.get();
            resp.setContentLength(b.length);
            resp.getOutputStream().write(b, 0, b.length);
            resp.getOutputStream().flush();
        } else {
            this.sendResponse(resp, 404, "Portrait with ID " + portraitId + " not found");
        }
    }

    private static boolean isWebp(byte[] data) {
        return data != null && data.length >= 12
            && data[0] == 'R' && data[1] == 'I' && data[2] == 'F' && data[3] == 'F'
            && data[8] == 'W' && data[9] == 'E' && data[10] == 'B' && data[11] == 'P';
    }

    private Process startFfmpeg() throws IOException {
        java.util.List<String> command = java.util.Arrays.asList(
            "-hide_banner", "-loglevel", "error", "-i", "pipe:0",
            "-vf", "scale=256:256:force_original_aspect_ratio=increase,crop=256:256",
            "-frames:v", "1", "-f", "image2", "-vcodec", "mjpeg", "-q:v", "3", "pipe:1");
        try {
            java.util.List<String> full = new java.util.ArrayList<>();
            full.add("ffmpeg");
            full.addAll(command);
            return new ProcessBuilder(full).start();
        }
        catch (IOException first) {
            java.util.List<String> full = new java.util.ArrayList<>();
            full.add("/opt/ctbrec/ffmpeg/ffmpeg");
            full.addAll(command);
            return new ProcessBuilder(full).start();
        }
    }

    private byte[] convertWebpToJpeg(byte[] data) {
        if (!ImageServlet.isWebp(data)) {
            return data;
        }
        Process process = null;
        try {
            process = this.startFfmpeg();
            final byte[] input = data;
            final Process running = process;
            Thread writer = new Thread(() -> {
                try (OutputStream stdin = running.getOutputStream()) {
                    stdin.write(input);
                }
                catch (IOException iOException) {
                    // ffmpeg exited early; the exit status is checked below
                }
            }, "portrait-webp-encoder");
            writer.setDaemon(true);
            writer.start();
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            try (InputStream stdout = process.getInputStream()) {
                byte[] buffer = new byte[8192];
                int read;
                while ((read = stdout.read(buffer)) > 0) {
                    output.write(buffer, 0, read);
                }
            }
            if (!process.waitFor(30L, TimeUnit.SECONDS)) {
                process.destroyForcibly();
                log.warn("ffmpeg webp conversion timed out, keeping original bytes");
                return data;
            }
            writer.join(2000L);
            if (process.exitValue() != 0 || output.size() == 0) {
                log.warn("ffmpeg webp conversion failed with status {}, keeping original bytes", (Object)process.exitValue());
                return data;
            }
            return output.toByteArray();
        }
        catch (Exception e) {
            if (process != null) {
                process.destroyForcibly();
            }
            log.warn("Could not convert webp portrait to JPEG: {}", (Object)e.getMessage());
            return data;
        }
    }

    private void fetchAndServePreview(HttpServletResponse resp, String modelUrl, boolean previewOnly) {
        try {
            Site site;
            Optional<Model> modelOpt = this.recorder.getModels().stream().filter(m -> m.getUrl().equals(modelUrl)).findFirst();
            if (modelOpt.isEmpty()) {
                this.sendResponse(resp, 404, "{\"status\": \"error\", \"msg\": \"Model not found\"}");
                return;
            }
            Model model = modelOpt.get();
            String previewUrl;
            if (model instanceof PortraitUrlProvider) {
                // Sites such as Stripchat expose a dedicated live-snapshot
                // portrait URL.  Never fall back to the site avatar for these
                // models: the avatar is the default offline picture and looks
                // nothing like the stream.
                previewUrl = null;
                try {
                    previewUrl = ((PortraitUrlProvider)model).getPortraitUrl(false);
                }
                catch (Exception e) {
                    log.warn("Portrait URL provider failed for {}: {}", (Object)model.getName(), (Object)e.getMessage());
                }
                if (previewUrl == null || !previewUrl.toLowerCase().startsWith("http")
                        || previewUrl.toLowerCase().contains("/avatars/")) {
                    log.info("No stream snapshot available for model: {}", (Object)model.getName());
                    this.sendResponse(resp, 404, "{\"status\": \"error\", \"msg\": \"No stream snapshot available\"}");
                    return;
                }
                log.debug("Using portrait URL provider for model: {}", (Object)model.getName());
            } else {
                previewUrl = model.getPreview();
                if ((previewUrl == null || previewUrl.isEmpty() || !previewUrl.toLowerCase().startsWith("http")) && (site = model.getSite()) != null && site.supportsSearch()) {
                    try {
                        List<Model> results = site.search(model.getName());
                        Optional<Model> freshModel = results.stream().filter(m -> m.getUrl().equals(model.getUrl()) || m.getName().equalsIgnoreCase(model.getName())).findFirst();
                        if (freshModel.isPresent() && freshModel.get().getPreview() != null && freshModel.get().getPreview().startsWith("http")) {
                            previewUrl = freshModel.get().getPreview();
                            log.debug("Found preview URL from search: {}", (Object)previewUrl);
                        }
                    }
                    catch (Exception e) {
                        log.warn("Failed to search for fresh preview URL", (Throwable)e);
                    }
                }
                if (previewUrl == null || previewUrl.isEmpty() || !previewUrl.toLowerCase().startsWith("http")) {
                    this.sendResponse(resp, 404, "{\"status\": \"error\", \"msg\": \"No preview URL available\"}");
                    return;
                }
            }
            site = model.getSite();
            if (site == null) {
                this.sendResponse(resp, 500, "{\"status\": \"error\", \"msg\": \"Site not found\"}");
                return;
            }
            Request request = new Request.Builder().url(previewUrl).header("Accept", "*/*").header("User-Agent", this.config.getSettings().httpUserAgent).header("Referer", site.getBaseUrl()).build();
            try (Response response = this.lenientHttpClient.newCall(request).execute();){
                byte[] imageData;
                if (!response.isSuccessful() || response.body() == null) {
                    this.sendResponse(resp, 502, "{\"status\": \"error\", \"msg\": \"Failed to fetch preview: " + response.code() + "\"}");
                    return;
                }
                long contentLength = response.body().contentLength();
                if (contentLength > 0xA00000L) {
                    this.sendResponse(resp, 502, "{\"status\": \"error\", \"msg\": \"Preview image is too large\"}");
                    return;
                }
                byte[] rawImageData = this.readLimited(response.body().byteStream(), 0xA00000);
                String contentType = response.header("Content-Type", "image/jpeg");
                byte[] converted = this.convertWebpToJpeg(rawImageData);
                if (converted != rawImageData) {
                    rawImageData = converted;
                    contentType = "image/jpeg";
                }
                try {
                    BufferedImage original = this.readBoundedImage(rawImageData);
                    if (original == null) {
                        log.debug("Could not decode image, passing through raw bytes");
                        imageData = rawImageData;
                    } else {
                        BufferedImage cropped = this.cropToSquare(original);
                        BufferedImage scaled = this.scaleImage(cropped, 256);
                        ByteArrayOutputStream baos = new ByteArrayOutputStream();
                        ImageIO.write((RenderedImage)scaled, "jpg", baos);
                        imageData = baos.toByteArray();
                        contentType = "image/jpeg";
                    }
                }
                catch (NoClassDefFoundError | UnsatisfiedLinkError e) {
                    log.warn("ImageIO native libraries not available, passing through raw image without processing: {}", (Object)e.getMessage());
                    imageData = rawImageData;
                }
                if (!previewOnly) {
                    this.portraitStore.writePortrait(modelUrl, imageData);
                    log.info("Fetched and saved portrait for model: {}", (Object)model.getName());
                } else {
                    log.debug("Fetched portrait preview for model: {} (not saved)", (Object)model.getName());
                }
                resp.setStatus(200);
                resp.setContentType(contentType);
                resp.setHeader("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0");
                resp.setContentLength(imageData.length);
                resp.getOutputStream().write(imageData, 0, imageData.length);
                resp.getOutputStream().flush();
            }
        }
        catch (Exception e) {
            log.error("Failed to fetch preview", (Throwable)e);
            this.sendResponse(resp, 500, "{\"status\": \"error\", \"msg\": \"" + e.getMessage() + "\"}");
        }
    }

    private BufferedImage cropToSquare(BufferedImage img) {
        int h;
        int w = img.getWidth();
        if (w > (h = img.getHeight())) {
            int overlap = w - h;
            return img.getSubimage(overlap / 2, 0, h, h);
        }
        if (h > w) {
            int overlap = h - w;
            return img.getSubimage(0, overlap / 2, w, w);
        }
        return img;
    }

    private byte[] readLimited(InputStream input, int maxBytes) throws IOException {
        int read;
        ByteArrayOutputStream output = new ByteArrayOutputStream(Math.min(8192, maxBytes));
        byte[] buffer = new byte[8192];
        int total = 0;
        while ((read = input.read(buffer)) != -1) {
            if ((total += read) > maxBytes) {
                throw new IOException("Preview image exceeds the " + maxBytes + " byte limit");
            }
            output.write(buffer, 0, read);
        }
        return output.toByteArray();
    }

    /*
     * WARNING - Removed try catching itself - possible behaviour change.
     */
    private BufferedImage readBoundedImage(byte[] data) throws IOException {
        try (ImageInputStream imageInput = ImageIO.createImageInputStream(new ByteArrayInputStream(data));){
            Iterator<ImageReader> readers = ImageIO.getImageReaders(imageInput);
            if (!readers.hasNext()) {
                BufferedImage bufferedImage = null;
                return bufferedImage;
            }
            ImageReader reader = readers.next();
            try {
                reader.setInput(imageInput, true, true);
                int width = reader.getWidth(0);
                int height = reader.getHeight(0);
                if (width <= 0 || height <= 0 || (long)width * (long)height > 25000000L) {
                    throw new IOException("Preview image dimensions are too large");
                }
                BufferedImage bufferedImage = reader.read(0);
                reader.dispose();
                return bufferedImage;
            }
            catch (Throwable throwable) {
                reader.dispose();
                throw throwable;
            }
        }
    }

    private BufferedImage scaleImage(BufferedImage original, int targetSize) {
        Image scaled = original.getScaledInstance(targetSize, targetSize, 4);
        BufferedImage result = new BufferedImage(targetSize, targetSize, 1);
        Graphics2D g = result.createGraphics();
        g.drawImage(scaled, 0, 0, null);
        g.dispose();
        return result;
    }

    private void serveRecordingImage(HttpServletResponse resp, String filename) throws IOException {
        String recordingsDir = this.config.getSettings().recordingsDir;
        File imageFile = new File(recordingsDir, filename);
        if (!imageFile.exists() || !imageFile.isFile()) {
            this.sendResponse(resp, 404, "Image not found");
            return;
        }
        resp.setStatus(200);
        resp.setContentType("image/jpeg");
        Files.copy(imageFile.toPath(), (OutputStream)resp.getOutputStream());
        resp.getOutputStream().flush();
    }

    protected void doPost(HttpServletRequest req, HttpServletResponse resp) {
        String requestURI = req.getRequestURI().substring(req.getContextPath().length());
        log.debug("Portrait POST request: {}", (Object)requestURI);
        try {
            byte[] data = this.bodyAsByteArray(req, 0xA00000);
            log.debug("Portrait POST data size: {} bytes", (Object)data.length);
            boolean authenticated = this.checkAuthentication(req, data);
            if (!authenticated) {
                this.sendResponse(resp, 401, "{\"status\": \"error\", \"msg\": \"HMAC does not match\"}");
                return;
            }
            Matcher m = URL_PATTERN_PORTRAIT_BY_URL.matcher(requestURI);
            if (m.matches()) {
                String modelUrl = URLDecoder.decode(m.group(1), StandardCharsets.UTF_8);
                log.info("Saving portrait for model URL: {}", (Object)modelUrl);
                this.portraitStore.writePortrait(modelUrl, data);
                log.info("Portrait saved successfully for: {}", (Object)modelUrl);
                this.sendResponse(resp, 200, "{\"status\": \"success\"}");
            } else {
                log.warn("Portrait POST URL did not match pattern: {}", (Object)requestURI);
                this.sendResponse(resp, 400, "{\"status\": \"error\", \"msg\": \"Invalid URL\"}");
            }
        }
        catch (AbstractCtbrecServlet.PayloadTooLargeException e) {
            log.warn("Rejected oversized portrait: {}", (Object)e.getMessage());
            this.sendResponse(resp, 413, e.getMessage());
        }
        catch (Exception e) {
            log.error("Failed to save portrait: {}", (Object)e.getMessage(), (Object)e);
            this.sendResponse(resp, 500, "Internal Server Error");
        }
    }

    protected void doDelete(HttpServletRequest req, HttpServletResponse resp) {
        String requestURI = req.getRequestURI().substring(req.getContextPath().length());
        try {
            boolean authenticated = this.checkAuthentication(req, "");
            if (!authenticated) {
                this.sendResponse(resp, 401, "{\"status\": \"error\", \"msg\": \"HMAC does not match\"}");
                return;
            }
            Matcher m = URL_PATTERN_PORTRAIT_BY_URL.matcher(requestURI);
            if (m.matches()) {
                String modelUrl = URLDecoder.decode(m.group(1), StandardCharsets.UTF_8);
                this.portraitStore.removePortrait(modelUrl);
            }
        }
        catch (Exception e) {
            log.error("Internal Server Error", (Throwable)e);
            this.sendResponse(resp, 500, "Internal Server Error");
        }
    }
}

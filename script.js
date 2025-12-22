// ===== THREE.JS 3D MODEL BACKGROUND =====
const scene = new THREE.Scene();
scene.background = null; // Transparent background

// Camera setup
const camera = new THREE.PerspectiveCamera(
    75,
    window.innerWidth / window.innerHeight,
    0.1,
    1000
);
camera.position.set(0, 1, 15); // Moved camera further back

// Renderer setup
const renderer = new THREE.WebGLRenderer({
    antialias: true,
    alpha: true
});
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.setPixelRatio(window.devicePixelRatio);
renderer.setClearColor(0x000000, 0); // Transparent
document.getElementById('canvas-container').appendChild(renderer.domElement);

// Create environment with logo for reflections
const canvas = document.createElement('canvas');
canvas.width = 1024;
canvas.height = 512;
const ctx = canvas.getContext('2d');

let envTexture;
let envReady = false;

// Load logo and create environment
const logoImage = new Image();
logoImage.crossOrigin = 'anonymous';
logoImage.onload = function() {
    console.log('Logo image loaded, creating environment...');

    // Fill with dark background first
    ctx.fillStyle = '#0a0e12';
    ctx.fillRect(0, 0, 1024, 512);

    // Draw one large centered logo
    ctx.globalCompositeOperation = 'source-over';
    ctx.globalAlpha = 1.0; // Full opacity

    // Single large logo - offset to center reflection on angled glasses
    const logoSize = 500; // Smaller for cleaner reflection
    const centerX = (1024 - logoSize) / 2 + 180; // Shift right to center on both lenses
    const centerY = (512 - logoSize) / 2;
    ctx.drawImage(logoImage, centerX, centerY, logoSize, logoSize);

    // Add subtle blue tint overlay for brand colors
    ctx.globalCompositeOperation = 'overlay';
    ctx.globalAlpha = 0.2; // Even more subtle
    const gradient = ctx.createLinearGradient(0, 0, 0, 512);
    gradient.addColorStop(0, '#0ea5e9');
    gradient.addColorStop(1, '#38bdf8');
    ctx.fillStyle = gradient;
    ctx.fillRect(0, 0, 1024, 512);

    // Create environment texture
    envTexture = new THREE.CanvasTexture(canvas);
    envTexture.mapping = THREE.EquirectangularReflectionMapping;
    envTexture.needsUpdate = true;
    scene.environment = envTexture;
    envReady = true;

    console.log('Logo environment created and applied successfully');

    // Update model materials if model already loaded
    if (model) {
        updateModelMaterials();
    }
};
logoImage.onerror = function() {
    console.warn('Logo failed to load, using gradient only');
    // Fallback to gradient only
    const gradient = ctx.createLinearGradient(0, 0, 0, 512);
    gradient.addColorStop(0, '#0ea5e9');
    gradient.addColorStop(0.5, '#38bdf8');
    gradient.addColorStop(1, '#000000');
    ctx.fillStyle = gradient;
    ctx.fillRect(0, 0, 1024, 512);

    envTexture = new THREE.CanvasTexture(canvas);
    envTexture.mapping = THREE.EquirectangularReflectionMapping;
    scene.environment = envTexture;
    envReady = true;

    if (model) {
        updateModelMaterials();
    }
};
logoImage.src = 'sparks_logo.jpg';

// Function to update model materials with environment map
function updateModelMaterials() {
    if (!model || !envTexture) return;

    console.log('Updating model materials with environment map...');
    let materialCount = 0;

    model.traverse((child) => {
        if (child.isMesh && child.material) {
            materialCount++;
            const mat = child.material;
            const matName = mat.name ? mat.name.toLowerCase() : '';

            console.log('Material name:', mat.name, 'Has transmission:', mat.transmission);

            // Apply environment map to all materials
            mat.envMap = envTexture;

            // Check if this is a lens (usually has transmission or has "lens" in name)
            // Make sure nose pads, bridge, and supports are NOT treated as lenses
            const isLens = (mat.transmission > 0 || matName.includes('lens') || matName.includes('glass'))
                && !matName.includes('nose')
                && !matName.includes('pad')
                && !matName.includes('bridge')
                && !matName.includes('support');

            if (isLens) {
                // Lenses - reflective with logo, maintain transparency
                mat.envMapIntensity = 5.0; // Very strong reflection for high reflectivity
                mat.metalness = 0.2; // Slightly higher metalness for more reflection
                mat.roughness = 0.001; // Nearly mirror-smooth for maximum reflections
                if (mat.transmission !== undefined) {
                    mat.transmission = 0.9; // Keep transparency
                }
                console.log('  -> Configured as LENS (reflective with logo)');
            } else {
                // Frames - chrome/metallic
                mat.envMapIntensity = 4.0; // High reflection for chrome
                mat.metalness = 1.0; // Full metallic for chrome
                mat.roughness = 0.001; // Mirror-smooth for maximum chrome reflections
                console.log('  -> Configured as FRAME (chrome)');
            }

            mat.needsUpdate = true;
        }
    });

    console.log(`Updated ${materialCount} materials with environment map`);
}

// Lighting - much brighter for better sunglasses visibility
const ambientLight = new THREE.AmbientLight(0xffffff, 2.0); // Even brighter ambient
scene.add(ambientLight);

const mainLight = new THREE.DirectionalLight(0xffffff, 1.8); // Much brighter main
mainLight.position.set(5, 10, 5);
scene.add(mainLight);

const backLight = new THREE.DirectionalLight(0xffffff, 1.2); // Brighter back light
backLight.position.set(-5, 5, -5);
scene.add(backLight);

const fillLight = new THREE.DirectionalLight(0xffffff, 1.0); // Brighter fill
fillLight.position.set(0, -5, 0);
scene.add(fillLight);

// Additional front light for chrome reflections
const frontLight = new THREE.DirectionalLight(0xffffff, 1.2); // Brighter front
frontLight.position.set(0, 0, 10);
scene.add(frontLight);

// Additional side lights for better coverage
const leftLight = new THREE.DirectionalLight(0xffffff, 0.8);
leftLight.position.set(-10, 0, 5);
scene.add(leftLight);

const rightLight = new THREE.DirectionalLight(0xffffff, 0.8);
rightLight.position.set(10, 0, 5);
scene.add(rightLight);

// Dynamic mouse spotlight
const mouseLight = new THREE.SpotLight(0xffffff, 4); // Even brighter spotlight
mouseLight.position.set(0, 0, 10);
mouseLight.angle = Math.PI / 6;
mouseLight.penumbra = 0.3;
mouseLight.decay = 2;
mouseLight.distance = 50;
scene.add(mouseLight);

// ===== PARTICLE NETWORK BACKGROUND =====
const particleCount = 400; // Much more particles
const particlePositions = [];
const particleGeometry = new THREE.BufferGeometry();
const particleMaterial = new THREE.PointsMaterial({
    color: 0x0ea5e9,
    size: 0.4, // Even larger particles
    transparent: true,
    opacity: 0.75, // More prominent
    blending: THREE.AdditiveBlending,
    sizeAttenuation: true // Particles get bigger as they approach
});

// Create particles in 3D space with wider distribution
const positions = new Float32Array(particleCount * 3);
for (let i = 0; i < particleCount; i++) {
    const x = (Math.random() - 0.5) * 100; // Even wider spread
    const y = (Math.random() - 0.5) * 100; // Even wider spread
    const z = (Math.random() - 0.5) * 60 - 30; // Deep background to behind glasses

    positions[i * 3] = x;
    positions[i * 3 + 1] = y;
    positions[i * 3 + 2] = z;

    particlePositions.push(new THREE.Vector3(x, y, z));
}

particleGeometry.setAttribute('position', new THREE.BufferAttribute(positions, 3));
const particles = new THREE.Points(particleGeometry, particleMaterial);
scene.add(particles);

// Create lines connecting nearby particles
const lineMaterial = new THREE.LineBasicMaterial({
    color: 0x0ea5e9,
    transparent: true,
    opacity: 0.5, // Even more prominent lines
    blending: THREE.AdditiveBlending
});

const lineGeometry = new THREE.BufferGeometry();
const linePositions = [];
const maxDistance = 12; // Longer connections for denser network

function updateParticleLines() {
    linePositions.length = 0;

    for (let i = 0; i < particlePositions.length; i++) {
        for (let j = i + 1; j < particlePositions.length; j++) {
            const distance = particlePositions[i].distanceTo(particlePositions[j]);
            if (distance < maxDistance) {
                linePositions.push(
                    particlePositions[i].x, particlePositions[i].y, particlePositions[i].z,
                    particlePositions[j].x, particlePositions[j].y, particlePositions[j].z
                );
            }
        }
    }

    lineGeometry.setAttribute('position', new THREE.Float32BufferAttribute(linePositions, 3));
}

updateParticleLines();
const lines = new THREE.LineSegments(lineGeometry, lineMaterial);
scene.add(lines);

// Mouse tracking for interactive rotation
let mouseX = 0;
let mouseY = 0;
let targetRotationX = 0;
let targetRotationY = 0;

// Track mouse movement
document.addEventListener('mousemove', (event) => {
    // Normalize mouse position to -1 to 1
    mouseX = (event.clientX / window.innerWidth) * 2 - 1;
    mouseY = (event.clientY / window.innerHeight) * 2 - 1;
});

// Mobile accelerometer support for gyroscope-based interaction
let isUsingAccelerometer = false;

// Check if device supports orientation
if (window.DeviceOrientationEvent) {
    // Request permission for iOS 13+
    if (typeof DeviceOrientationEvent.requestPermission === 'function') {
        // iOS requires user interaction first - we'll auto-request on first touch
        document.addEventListener('touchstart', requestOrientationPermission, { once: true });
    } else {
        // Non-iOS devices
        enableAccelerometer();
    }
}

function requestOrientationPermission() {
    DeviceOrientationEvent.requestPermission()
        .then(permissionState => {
            if (permissionState === 'granted') {
                enableAccelerometer();
            }
        })
        .catch(console.error);
}

function enableAccelerometer() {
    window.addEventListener('deviceorientation', handleOrientation);
    isUsingAccelerometer = true;
}

function handleOrientation(event) {
    // Get device orientation (beta = front-to-back tilt, gamma = left-to-right tilt)
    const beta = event.beta;   // -180 to 180 degrees (front-back tilt)
    const gamma = event.gamma;  // -90 to 90 degrees (left-right tilt)

    if (beta !== null && gamma !== null) {
        // Convert to normalized values (-1 to 1) for consistency with mouse movement
        // Gamma (left-right): -90 to 90 -> map to -1 to 1
        mouseX = Math.max(-1, Math.min(1, gamma / 45)); // Divide by 45 for sensitivity

        // Beta (front-back): Use range around portrait position (around 90 degrees in portrait)
        // Adjust for portrait mode: 90 is neutral, tilt forward/back from there
        const adjustedBeta = beta - 90; // Center around 0
        mouseY = Math.max(-1, Math.min(1, adjustedBeta / 45)); // Divide by 45 for sensitivity
    }
}

// Load GLB model
let model;
const loader = new THREE.GLTFLoader();

loader.load(
    'SunglassesKhronos.glb',
    function (gltf) {
        model = gltf.scene;

        // Center and scale the model
        const box = new THREE.Box3().setFromObject(model);
        const center = box.getCenter(new THREE.Vector3());
        const size = box.getSize(new THREE.Vector3());

        // Center the model
        model.position.sub(center);

        // Scale to fit screen nicely - sunglasses are smaller, so scale more
        const maxDim = Math.max(size.x, size.y, size.z);
        const scale = 28.08 / maxDim; // 20% larger than 23.4 for better visibility
        model.scale.setScalar(scale);

        // Position sunglasses - adjust for better viewing angle
        model.position.y = -2;
        model.rotation.y = 0.3; // Slight angle to show off the design

        scene.add(model);

        // Apply environment map if ready
        if (envReady) {
            updateModelMaterials();
        }
    },
    function (xhr) {
        console.log((xhr.loaded / xhr.total * 100) + '% loaded');
    },
    function (error) {
        console.error('Error loading sunglasses model:', error);
    }
);

// Handle window resize
window.addEventListener('resize', () => {
    camera.aspect = window.innerWidth / window.innerHeight;
    camera.updateProjectionMatrix();
    renderer.setSize(window.innerWidth, window.innerHeight);
});

// Animation loop
function animate() {
    requestAnimationFrame(animate);

    if (model) {
        // Calculate target rotation based on mouse position
        targetRotationY = mouseX * 0.3; // Horizontal rotation (max ±0.3 radians ≈ ±17 degrees)
        targetRotationX = mouseY * 0.2; // Vertical rotation (max ±0.2 radians ≈ ±11 degrees)

        // Smooth interpolation for natural movement
        model.rotation.y += (targetRotationY - model.rotation.y) * 0.05;
        model.rotation.x += (targetRotationX - model.rotation.x) * 0.05;
    }

    // Subtle particle network movement based on mouse (slower, more subtle)
    particles.rotation.y += (mouseX * 0.1 - particles.rotation.y) * 0.02;
    particles.rotation.x += (mouseY * 0.05 - particles.rotation.x) * 0.02;
    lines.rotation.y = particles.rotation.y;
    lines.rotation.x = particles.rotation.x;

    // Animate particles moving slowly towards the camera
    const particlePositionsArray = particleGeometry.attributes.position.array;
    let needsLineUpdate = false;

    for (let i = 0; i < particleCount; i++) {
        const i3 = i * 3;

        // Move particle forward (towards camera) slowly
        particlePositionsArray[i3 + 2] += 0.05; // Slow forward movement
        particlePositions[i].z += 0.05;

        // Reset particle to back if it gets too close
        if (particlePositionsArray[i3 + 2] > 15) {
            particlePositionsArray[i3 + 2] = -45; // Reset to far back
            particlePositions[i].z = -45;
            needsLineUpdate = true;
        }
    }

    particleGeometry.attributes.position.needsUpdate = true;

    // Update connecting lines periodically
    if (needsLineUpdate) {
        updateParticleLines();
    }

    // Update mouse spotlight position
    mouseLight.position.x = mouseX * 8;
    mouseLight.position.y = -mouseY * 6 + 2;
    mouseLight.target.position.set(0, 0, 0);
    mouseLight.target.updateMatrixWorld();

    renderer.render(scene, camera);
}

// Start animation
animate();


// ===== PAINT REVEAL EFFECT =====
const paintCanvas = document.getElementById('paint-canvas');
const paintCtx = paintCanvas.getContext('2d');

// Set canvas size
function resizePaintCanvas() {
    paintCanvas.width = window.innerWidth;
    paintCanvas.height = window.innerHeight;
    drawInitialText();
}
resizePaintCanvas();
window.addEventListener('resize', resizePaintCanvas);

// Draw the hidden text initially
function drawInitialText() {
    // Keep canvas clear - helmet always visible
    paintCtx.clearRect(0, 0, paintCanvas.width, paintCanvas.height);
}

// Raycaster for detecting mouse over helmet
const raycaster = new THREE.Raycaster();
const mouseVector = new THREE.Vector2();
let isOverHelmet = false;
let lastPaintPos = null;

// Track current mouse position
let currentMousePos = { x: 0, y: 0 };

// Track mouse movement for raycasting
document.addEventListener('mousemove', (event) => {
    currentMousePos = { x: event.clientX, y: event.clientY };

    // Update raycaster
    mouseVector.x = (event.clientX / window.innerWidth) * 2 - 1;
    mouseVector.y = -(event.clientY / window.innerHeight) * 2 + 1;

    raycaster.setFromCamera(mouseVector, camera);

    if (model) {
        const intersects = raycaster.intersectObject(model, true);
        isOverHelmet = intersects.length > 0;

        // Update cursor
        if (isOverHelmet) {
            document.body.classList.add('painting');
        } else {
            document.body.classList.remove('painting');
        }
    }
});

// Track lagging mouse position for delay effect
let laggedMousePos = { x: 0, y: 0 };
const LAG_FACTOR = 0.02; // Lower = more lag/delay (increased delay)

// Continuous render loop for spotlight effect (disabled - text reveal removed)
function renderSpotlight() {
    // Clear canvas and keep it empty (text reveal effect removed)
    paintCtx.clearRect(0, 0, paintCanvas.width, paintCanvas.height);
    requestAnimationFrame(renderSpotlight);
}

renderSpotlight();


// ===== PARALLAX SCROLL EFFECT =====
const canvasContainer = document.getElementById('canvas-container');
const paintCanvasElement = document.getElementById('paint-canvas');

window.addEventListener('scroll', () => {
    const scrollY = window.scrollY;

    // Different speeds for depth effect
    const helmetOffset = scrollY * 0.5; // Helmet moves slower (appears farther)
    const textOffset = scrollY * 0.8; // Text moves faster (appears closer)

    canvasContainer.style.transform = `translateY(-${helmetOffset}px)`;
    paintCanvasElement.style.transform = `translateY(-${textOffset}px)`;
});


// ===== NAVIGATION =====
const navbar = document.querySelector('.navbar');
const navBurger = document.getElementById('navBurger');
const navLinks = document.querySelector('.nav-links');

// Navbar scroll effect
window.addEventListener('scroll', () => {
    if (window.scrollY > 100) {
        navbar.classList.add('scrolled');
    } else {
        navbar.classList.remove('scrolled');
    }

});

// Mobile burger menu
navBurger?.addEventListener('click', (e) => {
    e.stopPropagation();
    navLinks.classList.toggle('active');
    navBurger.classList.toggle('active');
});

// Close menu when clicking nav links
document.querySelectorAll('.nav-links a').forEach(link => {
    link.addEventListener('click', () => {
        navLinks.classList.remove('active');
        navBurger.classList.remove('active');
    });
});

// Close menu when clicking outside
document.addEventListener('click', (e) => {
    if (!navLinks.contains(e.target) && !navBurger.contains(e.target)) {
        navLinks.classList.remove('active');
        navBurger.classList.remove('active');
    }
});

// Logo click to scroll to top
const navLogo = document.querySelector('.nav-logo');
navLogo?.addEventListener('click', (e) => {
    e.preventDefault();
    window.scrollTo({
        top: 0,
        behavior: 'smooth'
    });
});

// Smooth scroll for navigation links
document.querySelectorAll('a[href^="#"]').forEach(anchor => {
    anchor.addEventListener('click', function (e) {
        // Skip if this is the logo (already handled above)
        if (this.classList.contains('nav-logo')) return;

        e.preventDefault();
        const target = document.querySelector(this.getAttribute('href'));
        if (target) {
            target.scrollIntoView({
                behavior: 'smooth',
                block: 'start'
            });
            navLinks.classList.remove('active');
        }
    });
});

// ===== YOUTUBE INTEGRATION =====
const YOUTUBE_CHANNEL_ID = 'UCuUCB1yQyF23u5ESGvNZKNg';
const YOUTUBE_API_KEY = 'AIzaSyBSELHZRfCG2MnQD_HABaKbFGbKRxqyf4M';

// Load YouTube subscriber count
async function loadSubscriberCount() {
    try {
        // Get subscriber count directly using channel ID
        const statsUrl = `https://www.googleapis.com/youtube/v3/channels?part=statistics&id=${YOUTUBE_CHANNEL_ID}&key=${YOUTUBE_API_KEY}`;
        const statsResponse = await fetch(statsUrl);
        const statsData = await statsResponse.json();

        if (statsData.items && statsData.items.length > 0) {
            const subCount = parseInt(statsData.items[0].statistics.subscriberCount);

            // Format subscriber count
            let formattedCount;
            if (subCount >= 1000000) {
                formattedCount = (subCount / 1000000).toFixed(1) + 'M+';
            } else if (subCount >= 1000) {
                formattedCount = (subCount / 1000).toFixed(1) + 'K+';
            } else {
                formattedCount = subCount + '+';
            }

            // Update the display
            document.getElementById('subscriber-count').textContent = formattedCount;
            console.log('YouTube subscriber count loaded:', formattedCount);
        }
    } catch (error) {
        console.error('Error loading YouTube subscriber count:', error);
        // Keep the default "2.5K+" if API fails
    }
}

// Load subscriber count on page load
document.addEventListener('DOMContentLoaded', loadSubscriberCount);

async function loadYouTubeVideos() {
    const videosGrid = document.getElementById('videosGrid');

    try {
        // Fetch latest videos from YouTube channel
        const videosUrl = `https://www.googleapis.com/youtube/v3/search?key=${YOUTUBE_API_KEY}&channelId=${YOUTUBE_CHANNEL_ID}&part=snippet,id&order=date&maxResults=8&type=video`;
        const response = await fetch(videosUrl);
        const data = await response.json();

        if (data.items && data.items.length > 0) {
            videosGrid.innerHTML = data.items.map(item => {
                const videoId = item.id.videoId;
                const title = item.snippet.title;
                const thumbnail = item.snippet.thumbnails.high.url;
                const videoUrl = `https://www.youtube.com/watch?v=${videoId}`;

                return `
                    <a href="${videoUrl}" target="_blank" class="video-card">
                        <div class="video-thumbnail">
                            <img src="${thumbnail}" alt="${title}">
                            <div class="play-button">
                                <svg width="48" height="48" viewBox="0 0 24 24" fill="white">
                                    <path d="M8 5v14l11-7z"/>
                                </svg>
                            </div>
                        </div>
                        <div class="video-info">
                            <h3 class="video-title">${title}</h3>
                            <p class="video-meta">SparksTheory</p>
                        </div>
                    </a>
                `;
            }).join('');

            console.log('YouTube videos loaded:', data.items.length);
        }
    } catch (error) {
        console.error('Error loading YouTube videos:', error);
        // Fallback to placeholder
        videosGrid.innerHTML = `
            <div class="video-placeholder">
                <p>Unable to load videos. <a href="https://www.youtube.com/@SparksTheory" target="_blank">Visit my YouTube channel</a></p>
            </div>
        `;
    }
}

document.addEventListener('DOMContentLoaded', loadYouTubeVideos);

// ===== GT7 STATS AUTO-LOADER =====
const checkerResults = document.getElementById('checkerResults');

// Your GT7 credentials (from lookupPSN API)
const MY_USER_ID = '85596fe8-f2f8-45c1-9474-f3357e8d9446';
const MY_PSN = 'SparksTheory';

// Load stats automatically on page load
async function loadMyGT7Stats() {
    try {
        // Use CORS proxy to fetch your full stats history
        const apiUrl = `https://gtstats.live/api/getDriverStatsHistory?user_id=${MY_USER_ID}&psn=${encodeURIComponent(MY_PSN)}`;
        const proxyUrl = `https://api.allorigins.win/get?url=${encodeURIComponent(apiUrl)}`;

        const response = await fetch(proxyUrl);
        const proxyData = await response.json();

        console.log('GT7 Stats Response:', proxyData);

        if (!response.ok) {
            throw new Error(`API returned ${response.status}`);
        }

        const data = JSON.parse(proxyData.contents);
        displayDriverStats(MY_PSN, data);

    } catch (error) {
        console.error('Error loading GT7 stats:', error);

        // Fallback to manual stats display
        checkerResults.innerHTML = `
            <div style="max-width: 600px; margin: 0 auto;">
                <div style="display: grid; grid-template-columns: repeat(2, 1fr); gap: 1.5rem; margin-bottom: 2rem;">
                    <div style="background: linear-gradient(135deg, rgba(0,255,136,0.1) 0%, rgba(0,255,136,0.05) 100%); border: 2px solid rgba(0,255,136,0.3); border-radius: 12px; padding: 2rem; text-align: center; position: relative; overflow: hidden;">
                        <div style="position: absolute; top: 0; left: 0; right: 0; height: 4px; background: linear-gradient(90deg, var(--color-primary), var(--color-secondary));"></div>
                        <div style="font-size: 0.75rem; text-transform: uppercase; letter-spacing: 2px; color: var(--color-text-muted); margin-bottom: 0.5rem;">Driver Rating</div>
                        <div style="font-size: 3rem; font-weight: 900; font-family: var(--font-display); color: var(--color-primary); line-height: 1; margin-bottom: 0.25rem;">A+</div>
                        <div style="font-size: 1.25rem; font-weight: 600; color: rgba(255,255,255,0.8);">55,316 DR</div>
                    </div>
                    <div style="background: linear-gradient(135deg, rgba(14,165,233,0.1) 0%, rgba(14,165,233,0.05) 100%); border: 2px solid rgba(14,165,233,0.3); border-radius: 12px; padding: 2rem; text-align: center; position: relative; overflow: hidden;">
                        <div style="position: absolute; top: 0; left: 0; right: 0; height: 4px; background: linear-gradient(90deg, var(--color-secondary), var(--color-primary));"></div>
                        <div style="font-size: 0.75rem; text-transform: uppercase; letter-spacing: 2px; color: var(--color-text-muted); margin-bottom: 0.5rem;">Sportsmanship</div>
                        <div style="font-size: 3rem; font-weight: 900; font-family: var(--font-display); color: var(--color-secondary); line-height: 1; margin-bottom: 0.25rem;">S</div>
                        <div style="font-size: 1.25rem; font-weight: 600; color: rgba(255,255,255,0.8);">99 SR</div>
                    </div>
                </div>
                <div style="background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.1); border-radius: 12px; padding: 1.5rem;">
                    <div style="display: grid; grid-template-columns: repeat(2, 1fr); gap: 1.5rem;">
                        <div style="text-align: center;">
                            <div style="font-size: 2rem; font-weight: 700; color: var(--color-primary);">SparksTheory</div>
                            <div style="font-size: 0.875rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 1px;">PSN ID</div>
                        </div>
                        <div style="text-align: center;">
                            <div style="font-size: 2rem; font-weight: 700; color: var(--color-text);">Active</div>
                            <div style="font-size: 0.875rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 1px;">GT7 Sport Mode</div>
                        </div>
                    </div>
                </div>
            </div>
        `;
    }
}

// Load stats when page is ready
document.addEventListener('DOMContentLoaded', loadMyGT7Stats);

function displayDriverStats(psnId, data) {
    // Parse the API response and display relevant stats
    console.log('API Response:', data);

    // Check if we have valid data
    if (!data || (Array.isArray(data) && data.length === 0)) {
        checkerResults.innerHTML = `
            <div style="text-align: left;">
                <p style="color: var(--color-accent);">No stats found for "${psnId}"</p>
                <p style="color: var(--color-text-muted); font-size: 0.9rem; margin-top: 1rem;">
                    Make sure the PSN ID is correct and the player has participated in GT7 Sport mode.
                </p>
            </div>
        `;
        return;
    }

    // Helper function to convert SR number to letter grade (API uses 0-6 scale)
    function getSRGrade(sr) {
        // GT7 API SR scale: 6=S, 5=A, 4=B, 3=C, 2=D, 1=E, 0=E
        const grades = ['E', 'E', 'D', 'C', 'B', 'A', 'S'];
        return grades[sr] || 'E';
    }

    // Get the most recent stats (data is an object with numeric keys)
    const latestStats = data["0"] || data[0] || data;

    // Debug: Log all available fields
    console.log('All stats fields:', latestStats);

    // Extract GT7 stat fields from API using correct field names
    const drPoints = latestStats.dr || 0;
    const driverRating = latestStats.rank || 'E';  // API provides the letter grade directly!
    const srValue = latestStats.sr || 0;
    const sportsmanship = getSRGrade(srValue);
    const totalRaces = latestStats.raceCount || 0;
    const wins = latestStats.winCount || 0;
    const poles = latestStats.polePositionCount || 0;
    const fastestLaps = latestStats.fastestLapCount || 0;

    console.log('DR Points:', drPoints, 'DR Grade:', driverRating, 'SR Value:', srValue, 'SR Grade:', sportsmanship);

    checkerResults.innerHTML = `
        <div style="max-width: 700px; margin: 0 auto;">
            <!-- DR & SR Cards -->
            <div style="display: grid; grid-template-columns: repeat(2, 1fr); gap: 1.5rem; margin-bottom: 1.5rem;">
                <div style="background: linear-gradient(135deg, rgba(0,255,136,0.15) 0%, rgba(0,255,136,0.05) 100%); border: 2px solid rgba(0,255,136,0.4); border-radius: 16px; padding: 2rem; text-align: center; position: relative; overflow: hidden; box-shadow: 0 8px 32px rgba(0,255,136,0.15);">
                    <div style="position: absolute; top: 0; left: 0; right: 0; height: 4px; background: linear-gradient(90deg, var(--color-primary), var(--color-secondary));"></div>
                    <div style="font-size: 0.7rem; text-transform: uppercase; letter-spacing: 3px; color: var(--color-text-muted); margin-bottom: 0.5rem; font-weight: 600;">Driver Rating</div>
                    <div style="font-size: 3.5rem; font-weight: 900; font-family: var(--font-display); color: var(--color-primary); line-height: 1; margin-bottom: 0.5rem; text-shadow: 0 0 20px rgba(0,255,136,0.3);">${driverRating}</div>
                    <div style="font-size: 1.1rem; font-weight: 700; color: rgba(255,255,255,0.9);">${drPoints ? drPoints.toLocaleString() : '0'} <span style="color: var(--color-text-muted); font-weight: 500;">points</span></div>
                </div>
                <div style="background: linear-gradient(135deg, rgba(14,165,233,0.15) 0%, rgba(14,165,233,0.05) 100%); border: 2px solid rgba(14,165,233,0.4); border-radius: 16px; padding: 2rem; text-align: center; position: relative; overflow: hidden; box-shadow: 0 8px 32px rgba(14,165,233,0.15);">
                    <div style="position: absolute; top: 0; left: 0; right: 0; height: 4px; background: linear-gradient(90deg, var(--color-secondary), var(--color-primary));"></div>
                    <div style="font-size: 0.7rem; text-transform: uppercase; letter-spacing: 3px; color: var(--color-text-muted); margin-bottom: 0.5rem; font-weight: 600;">Sportsmanship</div>
                    <div style="font-size: 3.5rem; font-weight: 900; font-family: var(--font-display); color: var(--color-secondary); line-height: 1; margin-bottom: 0.5rem; text-shadow: 0 0 20px rgba(14,165,233,0.3);">${sportsmanship}</div>
                    <div style="font-size: 1.1rem; font-weight: 700; color: rgba(255,255,255,0.9);">${srValue ? srValue : '0'} <span style="color: var(--color-text-muted); font-weight: 500;">rating</span></div>
                </div>
            </div>

            <!-- Racing Stats Grid -->
            <div style="display: grid; grid-template-columns: repeat(2, 1fr); gap: 1rem; margin-bottom: 1.5rem;">
                <div style="background: rgba(255,255,255,0.05); border: 1px solid rgba(0,255,136,0.2); border-radius: 12px; padding: 1.5rem; text-align: center; transition: all 0.3s ease;">
                    <div style="font-size: 2.5rem; font-weight: 800; color: var(--color-primary); font-family: var(--font-display); margin-bottom: 0.25rem;">${totalRaces || 0}</div>
                    <div style="font-size: 0.75rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 2px; font-weight: 600;">Races</div>
                </div>
                <div style="background: rgba(255,255,255,0.05); border: 1px solid rgba(0,255,136,0.2); border-radius: 12px; padding: 1.5rem; text-align: center; transition: all 0.3s ease;">
                    <div style="font-size: 2.5rem; font-weight: 800; color: var(--color-primary); font-family: var(--font-display); margin-bottom: 0.25rem;">${wins || 0}</div>
                    <div style="font-size: 0.75rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 2px; font-weight: 600;">Wins</div>
                </div>
                <div style="background: rgba(255,255,255,0.05); border: 1px solid rgba(14,165,233,0.2); border-radius: 12px; padding: 1.5rem; text-align: center; transition: all 0.3s ease;">
                    <div style="font-size: 2.5rem; font-weight: 800; color: var(--color-secondary); font-family: var(--font-display); margin-bottom: 0.25rem;">${poles || 0}</div>
                    <div style="font-size: 0.75rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 2px; font-weight: 600;">Pole Positions</div>
                </div>
                <div style="background: rgba(255,255,255,0.05); border: 1px solid rgba(14,165,233,0.2); border-radius: 12px; padding: 1.5rem; text-align: center; transition: all 0.3s ease;">
                    <div style="font-size: 2.5rem; font-weight: 800; color: var(--color-secondary); font-family: var(--font-display); margin-bottom: 0.25rem;">${fastestLaps || 0}</div>
                    <div style="font-size: 0.75rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 2px; font-weight: 600;">Fastest Laps</div>
                </div>
            </div>

            <!-- PSN ID Badge -->
            <div style="background: linear-gradient(135deg, rgba(255,255,255,0.1) 0%, rgba(255,255,255,0.03) 100%); border: 1px solid rgba(255,255,255,0.15); border-radius: 12px; padding: 1.25rem; text-align: center;">
                <div style="font-size: 1.75rem; font-weight: 800; color: var(--color-primary); font-family: var(--font-display); letter-spacing: 1px;">${psnId}</div>
                <div style="font-size: 0.7rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 2px; margin-top: 0.25rem; font-weight: 600;">PSN ID • GT7 Sport Mode</div>
            </div>
        </div>
    `;
}

// ===== CONTACT FORM =====
const contactForm = document.getElementById('contactForm');

contactForm?.addEventListener('submit', (e) => {
    e.preventDefault();

    const formData = new FormData(contactForm);
    const submitBtn = contactForm.querySelector('button[type="submit"]');
    const originalText = submitBtn.textContent;

    submitBtn.textContent = 'Sending...';
    submitBtn.disabled = true;

    setTimeout(() => {
        submitBtn.textContent = 'Message Sent!';
        submitBtn.style.background = 'var(--color-secondary)';
        contactForm.reset();

        setTimeout(() => {
            submitBtn.textContent = originalText;
            submitBtn.disabled = false;
            submitBtn.style.background = '';
        }, 3000);
    }, 1500);
});

// ===== SCROLL ANIMATIONS =====
const observerOptions = {
    threshold: 0.1,
    rootMargin: '0px 0px -100px 0px'
};

const observer = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
        if (entry.isIntersecting) {
            entry.target.style.opacity = '1';
            entry.target.style.transform = 'translateY(0)';
        }
    });
}, observerOptions);

document.querySelectorAll('.section').forEach(section => {
    section.style.opacity = '0';
    section.style.transform = 'translateY(30px)';
    section.style.transition = 'opacity 0.8s ease, transform 0.8s ease';
    observer.observe(section);
});

// ===== CONSOLE WELCOME MESSAGE =====
console.log('%cSPARKSTHEORY', 'color: #0ea5e9; font-size: 48px; font-weight: bold; font-family: Rajdhani, sans-serif;');
console.log('%c🏎️ Welcome to the sparkstheory racing website!', 'color: #38bdf8; font-size: 16px;');
console.log('%cFeaturing live GT7 stats and premium 3D visuals!', 'color: #94a3b8; font-size: 12px;');

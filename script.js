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
camera.position.set(0, 1, 8);

// Renderer setup
const renderer = new THREE.WebGLRenderer({
    antialias: true,
    alpha: true
});
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.setPixelRatio(window.devicePixelRatio);
renderer.setClearColor(0x000000, 0); // Transparent
document.getElementById('canvas-container').appendChild(renderer.domElement);

// Lighting
const ambientLight = new THREE.AmbientLight(0xffffff, 0.8);
scene.add(ambientLight);

const mainLight = new THREE.DirectionalLight(0x00ff88, 1.5);
mainLight.position.set(5, 10, 5);
scene.add(mainLight);

const backLight = new THREE.DirectionalLight(0x0ea5e9, 1);
backLight.position.set(-5, 5, -5);
scene.add(backLight);

const fillLight = new THREE.DirectionalLight(0xffffff, 0.5);
fillLight.position.set(0, -5, 0);
scene.add(fillLight);

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

// Load GLB model
let model;
const loader = new THREE.GLTFLoader();

loader.load(
    'fbx.glb',
    function (gltf) {
        model = gltf.scene;

        // Center and scale the model
        const box = new THREE.Box3().setFromObject(model);
        const center = box.getCenter(new THREE.Vector3());
        const size = box.getSize(new THREE.Vector3());

        // Center the model
        model.position.sub(center);

        // Scale to fit (larger for full screen)
        const maxDim = Math.max(size.x, size.y, size.z);
        const scale = 8 / maxDim;
        model.scale.setScalar(scale);

        // Position model much lower
        model.position.y -= 3.5;

        // Face forward initially
        model.rotation.y = 0;

        scene.add(model);
        console.log('GLB model loaded successfully!');
    },
    function (xhr) {
        console.log((xhr.loaded / xhr.total * 100) + '% loaded');
    },
    function (error) {
        console.error('Error loading GLB model:', error);
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
const LAG_FACTOR = 0.04; // Lower = more lag/delay

// Continuous render loop for spotlight effect
function renderSpotlight() {
    // Clear canvas
    paintCtx.clearRect(0, 0, paintCanvas.width, paintCanvas.height);

    // Smoothly lag behind actual mouse position (creates delay effect)
    laggedMousePos.x += (currentMousePos.x - laggedMousePos.x) * LAG_FACTOR;
    laggedMousePos.y += (currentMousePos.y - laggedMousePos.y) * LAG_FACTOR;

    // First, draw the text
    paintCtx.globalCompositeOperation = 'source-over';

    const centerX = paintCanvas.width / 2;
    const centerY = paintCanvas.height * 0.4; // Positioned lower on screen

    paintCtx.font = 'bold 140px Rajdhani, sans-serif';
    paintCtx.textAlign = 'center';
    paintCtx.textBaseline = 'middle';

    // Create text gradient
    const textGradient = paintCtx.createLinearGradient(centerX - 400, centerY, centerX + 400, centerY);
    textGradient.addColorStop(0, '#ffffff');
    textGradient.addColorStop(0.5, '#00ff88');
    textGradient.addColorStop(1, '#0ea5e9');

    paintCtx.fillStyle = textGradient;
    paintCtx.fillText('SPARKSTHEORY', centerX, centerY);

    // Now apply invisible feathered mask (only keep text within circle)
    paintCtx.globalCompositeOperation = 'destination-in';

    const maskGradient = paintCtx.createRadialGradient(
        laggedMousePos.x, laggedMousePos.y, 0,
        laggedMousePos.x, laggedMousePos.y, 100
    );
    maskGradient.addColorStop(0, 'rgba(255, 255, 255, 1)');
    maskGradient.addColorStop(0.7, 'rgba(255, 255, 255, 0.5)');
    maskGradient.addColorStop(1, 'rgba(255, 255, 255, 0)'); // Feathered edge

    paintCtx.beginPath();
    paintCtx.arc(laggedMousePos.x, laggedMousePos.y, 100, 0, Math.PI * 2);
    paintCtx.fillStyle = maskGradient;
    paintCtx.fill();

    requestAnimationFrame(renderSpotlight);
}

renderSpotlight();


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
navBurger?.addEventListener('click', () => {
    navLinks.classList.toggle('active');
});

// Smooth scroll for navigation links
document.querySelectorAll('a[href^="#"]').forEach(anchor => {
    anchor.addEventListener('click', function (e) {
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

// ===== YOUTUBE VIDEO INTEGRATION =====
const YOUTUBE_CHANNEL_ID = 'UCyour_channel_id_here';
const YOUTUBE_API_KEY = 'your_api_key_here';

function loadYouTubeVideos() {
    const videosGrid = document.getElementById('videosGrid');

    const placeholderVideos = [
        {
            title: 'Epic GT7 Race at Spa | Close Finish!',
            thumbnail: 'https://via.placeholder.com/640x360/0a0e12/00ff88?text=Video+1',
            url: 'https://youtube.com/@SparksTheory'
        },
        {
            title: 'Setup Guide: Finding the Perfect Balance',
            thumbnail: 'https://via.placeholder.com/640x360/0a0e12/0ea5e9?text=Video+2',
            url: 'https://youtube.com/@SparksTheory'
        },
        {
            title: 'Overtaking Masterclass | Race Analysis',
            thumbnail: 'https://via.placeholder.com/640x360/0a0e12/00ff88?text=Video+3',
            url: 'https://youtube.com/@SparksTheory'
        }
    ];

    videosGrid.innerHTML = placeholderVideos.map(video => `
        <a href="${video.url}" target="_blank" class="video-card">
            <div class="video-thumbnail">
                <img src="${video.thumbnail}" alt="${video.title}">
            </div>
            <div class="video-info">
                <h3 class="video-title">${video.title}</h3>
                <p class="video-meta">SparksTheory • GT7</p>
            </div>
        </a>
    `).join('');
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
console.log('%cSPARKSTHEORY', 'color: #00ff88; font-size: 48px; font-weight: bold; font-family: Rajdhani, sans-serif;');
console.log('%c🏎️ Welcome to the sparkstheory racing website!', 'color: #0ea5e9; font-size: 16px;');
console.log('%cFeaturing live GT7 stats and premium 3D visuals!', 'color: #94a3b8; font-size: 12px;');

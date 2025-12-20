// ===== THREE.JS RACING TRACK SIMULATION =====
const scene = new THREE.Scene();
scene.fog = new THREE.Fog(0x0a0e12, 50, 200);

// Camera setup - Driver's POV
const camera = new THREE.PerspectiveCamera(
    90,
    window.innerWidth / window.innerHeight,
    0.1,
    500
);
camera.position.set(0, 1.2, 0); // Driver's eye level
camera.rotation.order = 'YXZ';

// Renderer setup
const renderer = new THREE.WebGLRenderer({
    antialias: true,
    alpha: true
});
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.setPixelRatio(window.devicePixelRatio);
document.getElementById('canvas-container').appendChild(renderer.domElement);

// Lighting
const ambientLight = new THREE.AmbientLight(0xffffff, 0.6);
scene.add(ambientLight);

const sunLight = new THREE.DirectionalLight(0xffffff, 0.8);
sunLight.position.set(50, 100, 50);
scene.add(sunLight);

// Track variables
let trackPosition = 0;
const trackWidth = 12;
const laneWidth = 4;
let speed = 0.15;

// Steering controls
let steeringAngle = 0;
let targetSteeringAngle = 0;
let cameraLateralOffset = 0;

// Create track surface
function createTrackSegment(zPosition) {
    const segmentGroup = new THREE.Group();

    // Main track surface with realistic texture
    const trackGeometry = new THREE.PlaneGeometry(trackWidth, 20, 32, 32);

    // Add subtle height variation for asphalt texture
    const positions = trackGeometry.attributes.position;
    for (let i = 0; i < positions.count; i++) {
        const noise = (Math.random() - 0.5) * 0.01;
        positions.setY(i, noise);
    }
    trackGeometry.computeVertexNormals();

    const trackMaterial = new THREE.MeshStandardMaterial({
        color: 0x1a1a1a,
        roughness: 0.95,
        metalness: 0.05
    });
    const trackMesh = new THREE.Mesh(trackGeometry, trackMaterial);
    trackMesh.rotation.x = -Math.PI / 2;
    trackMesh.position.z = zPosition;
    segmentGroup.add(trackMesh);

    // Center line
    const centerLineGeometry = new THREE.PlaneGeometry(0.2, 20);
    const centerLineMaterial = new THREE.MeshBasicMaterial({
        color: 0xffff00,
        transparent: true,
        opacity: 0.8
    });
    const centerLine = new THREE.Mesh(centerLineGeometry, centerLineMaterial);
    centerLine.rotation.x = -Math.PI / 2;
    centerLine.position.set(0, 0.01, zPosition);
    segmentGroup.add(centerLine);

    // Lane lines (dashed)
    for (let i = 0; i < 4; i++) {
        const laneLineGeometry = new THREE.PlaneGeometry(0.15, 2);
        const laneLineMaterial = new THREE.MeshBasicMaterial({
            color: 0xffffff,
            transparent: true,
            opacity: 0.7
        });
        const laneLine = new THREE.Mesh(laneLineGeometry, laneLineMaterial);
        laneLine.rotation.x = -Math.PI / 2;
        laneLine.position.set(-trackWidth / 4, 0.01, zPosition + i * 5 - 7.5);
        segmentGroup.add(laneLine);

        const laneLine2 = laneLine.clone();
        laneLine2.position.x = trackWidth / 4;
        segmentGroup.add(laneLine2);
    }

    // Realistic red/white alternating curbs (left side)
    const curbStripeLength = 1.0;
    const numStripes = Math.ceil(20 / curbStripeLength);

    for (let i = 0; i < numStripes; i++) {
        const isRed = i % 2 === 0;
        const curbGeometry = new THREE.BoxGeometry(0.6, 0.15, curbStripeLength);
        const curbMaterial = new THREE.MeshStandardMaterial({
            color: isRed ? 0xff0000 : 0xffffff,
            roughness: 0.7,
            metalness: 0.1
        });
        const curbStripe = new THREE.Mesh(curbGeometry, curbMaterial);
        curbStripe.position.set(
            -trackWidth / 2 - 0.3,
            0.05,
            zPosition - 10 + i * curbStripeLength + curbStripeLength / 2
        );
        segmentGroup.add(curbStripe);
    }

    // Realistic red/white alternating curbs (right side)
    for (let i = 0; i < numStripes; i++) {
        const isRed = i % 2 === 0;
        const curbGeometry = new THREE.BoxGeometry(0.6, 0.15, curbStripeLength);
        const curbMaterial = new THREE.MeshStandardMaterial({
            color: isRed ? 0xff0000 : 0xffffff,
            roughness: 0.7,
            metalness: 0.1
        });
        const curbStripe = new THREE.Mesh(curbGeometry, curbMaterial);
        curbStripe.position.set(
            trackWidth / 2 + 0.3,
            0.05,
            zPosition - 10 + i * curbStripeLength + curbStripeLength / 2
        );
        segmentGroup.add(curbStripe);
    }

    // Grass (left) with texture variation
    const grassGeometry = new THREE.PlaneGeometry(20, 20, 16, 16);
    const grassPositions = grassGeometry.attributes.position;
    for (let i = 0; i < grassPositions.count; i++) {
        const noise = (Math.random() - 0.5) * 0.05;
        grassPositions.setY(i, noise);
    }
    grassGeometry.computeVertexNormals();

    const grassMaterial = new THREE.MeshStandardMaterial({
        color: 0x1a4d1a,
        roughness: 1
    });
    const leftGrass = new THREE.Mesh(grassGeometry, grassMaterial);
    leftGrass.rotation.x = -Math.PI / 2;
    leftGrass.position.set(-trackWidth / 2 - 10, -0.05, zPosition);
    segmentGroup.add(leftGrass);

    // Grass (right)
    const rightGrass = new THREE.Mesh(grassGeometry.clone(), grassMaterial);
    rightGrass.rotation.x = -Math.PI / 2;
    rightGrass.position.set(trackWidth / 2 + 10, -0.05, zPosition);
    segmentGroup.add(rightGrass);

    // Barriers (left) - lower and further back
    const barrierGeometry = new THREE.BoxGeometry(0.3, 0.8, 20);
    const barrierMaterial = new THREE.MeshStandardMaterial({
        color: 0x00ff88,
        emissive: 0x00ff88,
        emissiveIntensity: 0.2,
        roughness: 0.5
    });
    const leftBarrier = new THREE.Mesh(barrierGeometry, barrierMaterial);
    leftBarrier.position.set(-trackWidth / 2 - 8, 0.4, zPosition);
    segmentGroup.add(leftBarrier);

    // Barriers (right)
    const rightBarrier = new THREE.Mesh(barrierGeometry, barrierMaterial);
    rightBarrier.position.set(trackWidth / 2 + 8, 0.4, zPosition);
    segmentGroup.add(rightBarrier);

    return segmentGroup;
}

// Create initial track segments
const trackSegments = [];
for (let i = 0; i < 15; i++) {
    const segment = createTrackSegment(i * 20 - 40);
    scene.add(segment);
    trackSegments.push(segment);
}

// Removed speed particles for cleaner view

// Mouse controls for steering
let mouseX = 0;
document.addEventListener('mousemove', (event) => {
    mouseX = (event.clientX / window.innerWidth) * 2 - 1;
    targetSteeringAngle = mouseX * 0.4; // Steering sensitivity
});

// Animation loop
function animate() {
    requestAnimationFrame(animate);

    // Update track position (forward motion)
    trackPosition += speed;

    // Move track segments
    trackSegments.forEach(segment => {
        segment.position.z += speed;

        // Reset segment position when it goes behind camera
        if (segment.position.z > 20) {
            segment.position.z -= trackSegments.length * 20;
        }
    });

    // Smooth steering
    steeringAngle += (targetSteeringAngle - steeringAngle) * 0.1;
    camera.rotation.y = steeringAngle;

    // Lateral camera movement (drift effect)
    cameraLateralOffset += (mouseX * 2 - cameraLateralOffset) * 0.05;
    camera.position.x = cameraLateralOffset;

    // Camera tilt effect (banking)
    camera.rotation.z = -steeringAngle * 0.2;

    renderer.render(scene, camera);
}

// Handle window resize
window.addEventListener('resize', () => {
    camera.aspect = window.innerWidth / window.innerHeight;
    camera.updateProjectionMatrix();
    renderer.setSize(window.innerWidth, window.innerHeight);
});

// Start animation
animate();

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

    // Increase speed based on scroll
    const scrollPercent = Math.min(window.scrollY / 1000, 1);
    speed = 0.15 + scrollPercent * 0.6;
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

// ===== GT7 DRIVER RATING CHECKER =====
const checkDriverBtn = document.getElementById('checkDriver');
const driverInput = document.getElementById('driverInput');
const checkerResults = document.getElementById('checkerResults');

// Allow Enter key to submit
driverInput?.addEventListener('keypress', (e) => {
    if (e.key === 'Enter') {
        checkDriverBtn.click();
    }
});

checkDriverBtn?.addEventListener('click', async () => {
    const psnId = driverInput.value.trim();

    if (!psnId) {
        checkerResults.innerHTML = '<p style="color: var(--color-accent);">Please enter a PSN ID</p>';
        return;
    }

    checkerResults.innerHTML = '<p>Searching GT7 stats...</p>';

    try {
        // Try AllOrigins CORS proxy which returns JSON with contents
        const apiUrl = `https://gtstats.live/api/getDriverStatsHistory?psn=${encodeURIComponent(psnId)}`;
        const proxyUrl = `https://api.allorigins.win/get?url=${encodeURIComponent(apiUrl)}`;

        const response = await fetch(proxyUrl);

        if (!response.ok) {
            throw new Error(`Proxy returned ${response.status}`);
        }

        const proxyData = await response.json();
        const data = JSON.parse(proxyData.contents);

        // Display the stats from the API response
        displayDriverStats(psnId, data);

    } catch (error) {
        console.error('Error fetching driver stats:', error);

        // Check if it's a CORS or network error
        const isCorsError = error.message.includes('Failed to fetch') || error.message.includes('CORS') || error.message.includes('NetworkError');

        checkerResults.innerHTML = `
            <div style="text-align: left;">
                <p style="color: var(--color-accent); margin-bottom: 1rem;">⚠️ Could not fetch stats for "${psnId}"</p>
                ${isCorsError ? `
                <p style="color: var(--color-text-muted); font-size: 0.9rem; margin-bottom: 1rem;">
                    <strong>Connection Issue:</strong> Unable to reach the gtstats.live API.
                </p>
                <p style="color: var(--color-text-muted); font-size: 0.9rem;">
                    Try checking your stats directly at
                    <a href="https://gtstats.live" target="_blank" style="color: var(--color-primary); text-decoration: underline;">gtstats.live</a>
                </p>
                ` : `
                <p style="color: var(--color-text-muted); font-size: 0.9rem;">
                    This could mean:
                    <ul style="margin-top: 0.5rem; padding-left: 1.5rem;">
                        <li>The PSN ID doesn't exist in GT7's database</li>
                        <li>The player hasn't played GT7 Sport mode</li>
                        <li>The gtstats.live service is temporarily unavailable</li>
                    </ul>
                </p>
                `}
                <p style="margin-top: 1rem; color: var(--color-text-muted); font-size: 0.85rem;">
                    Debug: ${error.message}
                </p>
            </div>
        `;
    }
});

function displayDriverStats(psnId, data) {
    // Parse the API response and display relevant stats
    // The exact structure depends on what gtstat.live returns
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

    // Get the most recent stats (assuming data is an array sorted by date)
    const latestStats = Array.isArray(data) ? data[0] : data;

    // Extract common GT7 stat fields (adjust based on actual API response)
    const driverRating = latestStats.driver_rating || latestStats.dr || 'N/A';
    const sportsmanship = latestStats.sportsmanship_rating || latestStats.sr || 'N/A';
    const totalRaces = latestStats.total_races || latestStats.races || 'N/A';
    const wins = latestStats.wins || 0;
    const drPoints = latestStats.driver_point || latestStats.dr_points || 'N/A';
    const srPoints = latestStats.sportsmanship_point || latestStats.sr_points || 'N/A';

    checkerResults.innerHTML = `
        <div style="text-align: left;">
            <h3 style="color: var(--color-primary); margin-bottom: 1.5rem;">Driver Profile</h3>
            <div style="display: grid; gap: 1rem;">
                <div style="display: flex; justify-content: space-between; padding: 0.5rem 0; border-bottom: 1px solid rgba(255,255,255,0.1);">
                    <span style="color: var(--color-text-muted);">PSN ID:</span>
                    <span style="font-weight: 600;">${psnId}</span>
                </div>
                <div style="display: flex; justify-content: space-between; padding: 0.5rem 0; border-bottom: 1px solid rgba(255,255,255,0.1);">
                    <span style="color: var(--color-text-muted);">Driver Rating:</span>
                    <span style="font-weight: 600; color: var(--color-primary);">${driverRating}${drPoints !== 'N/A' ? ` (${drPoints} pts)` : ''}</span>
                </div>
                <div style="display: flex; justify-content: space-between; padding: 0.5rem 0; border-bottom: 1px solid rgba(255,255,255,0.1);">
                    <span style="color: var(--color-text-muted);">Sportsmanship:</span>
                    <span style="font-weight: 600; color: var(--color-secondary);">${sportsmanship}${srPoints !== 'N/A' ? ` (${srPoints} pts)` : ''}</span>
                </div>
                ${totalRaces !== 'N/A' ? `
                <div style="display: flex; justify-content: space-between; padding: 0.5rem 0; border-bottom: 1px solid rgba(255,255,255,0.1);">
                    <span style="color: var(--color-text-muted);">Total Races:</span>
                    <span style="font-weight: 600;">${totalRaces}</span>
                </div>
                ` : ''}
                ${wins ? `
                <div style="display: flex; justify-content: space-between; padding: 0.5rem 0;">
                    <span style="color: var(--color-text-muted);">Wins:</span>
                    <span style="font-weight: 600; color: var(--color-primary);">${wins}</span>
                </div>
                ` : ''}
            </div>
            <p style="margin-top: 1.5rem; color: var(--color-text-muted); font-size: 0.85rem;">
                Data provided by <a href="https://gtstats.live" target="_blank" style="color: var(--color-primary);">gtstats.live</a>
            </p>
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
console.log('%cMove your mouse to steer - scroll to accelerate!', 'color: #94a3b8; font-size: 12px;');

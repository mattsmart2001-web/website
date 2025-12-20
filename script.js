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

// ===== GT7 STATS AUTO-LOADER =====
const checkerResults = document.getElementById('checkerResults');

// Your GT7 credentials (from lookupPSN API)
const MY_USER_ID = '85596fe8-f2f8-45c1-9474-f3357e8d9446';
const MY_PSN = 'SparksTheory';

// Load stats automatically on page load
async function loadMyGT7Stats() {
    try {
        // Use CORS proxy to fetch your DR stats
        const apiUrl = `https://gtstats.live/api/getDriverRating?user_id=${MY_USER_ID}`;
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

    // Helper function to convert DR points to letter grade
    function getDRGrade(points) {
        if (points >= 50000) return 'A+';
        if (points >= 40000) return 'A';
        if (points >= 30000) return 'B';
        if (points >= 10000) return 'C';
        if (points >= 4000) return 'D';
        return 'E';
    }

    // Helper function to convert SR number to letter grade
    function getSRGrade(sr) {
        // GT7 SR scale: S=99, A=80-98, B=65-79, C=40-64, D=20-39, E=1-19
        if (sr >= 99) return 'S';
        if (sr >= 80) return 'A';
        if (sr >= 65) return 'B';
        if (sr >= 40) return 'C';
        if (sr >= 20) return 'D';
        return 'E';
    }

    // Get the most recent stats (assuming data is an array sorted by date)
    const latestStats = Array.isArray(data) ? data[0] : data;

    // Extract GT7 stat fields from API
    const drPoints = latestStats.driver_rating || latestStats.dr || latestStats.driver_point || 0;
    const srValue = latestStats.sportsmanship_rating || latestStats.sr || latestStats.sportsmanship_point || 0;
    const totalRaces = latestStats.total_races || latestStats.races || 'N/A';
    const wins = latestStats.wins || 0;

    // Calculate letter grades
    const driverRating = getDRGrade(drPoints);
    const sportsmanship = getSRGrade(srValue);

    checkerResults.innerHTML = `
        <div style="max-width: 600px; margin: 0 auto;">
            <div style="display: grid; grid-template-columns: repeat(2, 1fr); gap: 1.5rem; margin-bottom: 2rem;">
                <div style="background: linear-gradient(135deg, rgba(0,255,136,0.1) 0%, rgba(0,255,136,0.05) 100%); border: 2px solid rgba(0,255,136,0.3); border-radius: 12px; padding: 2rem; text-align: center; position: relative; overflow: hidden;">
                    <div style="position: absolute; top: 0; left: 0; right: 0; height: 4px; background: linear-gradient(90deg, var(--color-primary), var(--color-secondary));"></div>
                    <div style="font-size: 0.75rem; text-transform: uppercase; letter-spacing: 2px; color: var(--color-text-muted); margin-bottom: 0.5rem;">Driver Rating</div>
                    <div style="font-size: 3rem; font-weight: 900; font-family: var(--font-display); color: var(--color-primary); line-height: 1; margin-bottom: 0.25rem;">${driverRating}</div>
                    <div style="font-size: 1.25rem; font-weight: 600; color: rgba(255,255,255,0.8);">${drPoints ? drPoints.toLocaleString() : 'N/A'} DR</div>
                </div>
                <div style="background: linear-gradient(135deg, rgba(14,165,233,0.1) 0%, rgba(14,165,233,0.05) 100%); border: 2px solid rgba(14,165,233,0.3); border-radius: 12px; padding: 2rem; text-align: center; position: relative; overflow: hidden;">
                    <div style="position: absolute; top: 0; left: 0; right: 0; height: 4px; background: linear-gradient(90deg, var(--color-secondary), var(--color-primary));"></div>
                    <div style="font-size: 0.75rem; text-transform: uppercase; letter-spacing: 2px; color: var(--color-text-muted); margin-bottom: 0.5rem;">Sportsmanship</div>
                    <div style="font-size: 3rem; font-weight: 900; font-family: var(--font-display); color: var(--color-secondary); line-height: 1; margin-bottom: 0.25rem;">${sportsmanship}</div>
                    <div style="font-size: 1.25rem; font-weight: 600; color: rgba(255,255,255,0.8);">${srValue ? srValue : 'N/A'} SR</div>
                </div>
            </div>
            <div style="background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.1); border-radius: 12px; padding: 1.5rem;">
                <div style="display: grid; grid-template-columns: repeat(${totalRaces !== 'N/A' && wins ? '3' : '2'}, 1fr); gap: 1.5rem;">
                    <div style="text-align: center;">
                        <div style="font-size: 2rem; font-weight: 700; color: var(--color-primary);">${psnId}</div>
                        <div style="font-size: 0.875rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 1px;">PSN ID</div>
                    </div>
                    ${totalRaces !== 'N/A' ? `
                    <div style="text-align: center;">
                        <div style="font-size: 2rem; font-weight: 700; color: var(--color-text);">${totalRaces}</div>
                        <div style="font-size: 0.875rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 1px;">Races</div>
                    </div>
                    ` : ''}
                    ${wins ? `
                    <div style="text-align: center;">
                        <div style="font-size: 2rem; font-weight: 700; color: var(--color-primary);">${wins}</div>
                        <div style="font-size: 0.875rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 1px;">Wins</div>
                    </div>
                    ` : `
                    <div style="text-align: center;">
                        <div style="font-size: 2rem; font-weight: 700; color: var(--color-text);">Active</div>
                        <div style="font-size: 0.875rem; color: var(--color-text-muted); text-transform: uppercase; letter-spacing: 1px;">GT7 Sport Mode</div>
                    </div>
                    `}
                </div>
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
console.log('%cMove your mouse to steer - scroll to accelerate!', 'color: #94a3b8; font-size: 12px;');

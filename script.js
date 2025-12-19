// ===== THREE.JS RACING BACKGROUND =====
const scene = new THREE.Scene();
scene.fog = new THREE.FogExp2(0x0a0e12, 0.015);

// Camera setup
const camera = new THREE.PerspectiveCamera(
    75,
    window.innerWidth / window.innerHeight,
    0.1,
    1000
);
camera.position.z = 30;
camera.position.y = 5;

// Renderer setup
const renderer = new THREE.WebGLRenderer({
    antialias: true,
    alpha: true
});
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.setPixelRatio(window.devicePixelRatio);
document.getElementById('canvas-container').appendChild(renderer.domElement);

// Lighting
const ambientLight = new THREE.AmbientLight(0xffffff, 0.3);
scene.add(ambientLight);

const pointLight1 = new THREE.PointLight(0x00ff88, 2, 100);
pointLight1.position.set(10, 10, 10);
scene.add(pointLight1);

const pointLight2 = new THREE.PointLight(0x0ea5e9, 2, 100);
pointLight2.position.set(-10, -10, 10);
scene.add(pointLight2);

// Create racing grid floor
const gridHelper = new THREE.GridHelper(200, 50, 0x00ff88, 0x0ea5e9);
gridHelper.position.y = -5;
gridHelper.material.opacity = 0.2;
gridHelper.material.transparent = true;
scene.add(gridHelper);

// Create racing track lines
const trackLines = [];
for (let i = 0; i < 5; i++) {
    const geometry = new THREE.BufferGeometry();
    const material = new THREE.LineBasicMaterial({
        color: i % 2 === 0 ? 0x00ff88 : 0x0ea5e9,
        transparent: true,
        opacity: 0.4
    });

    const points = [];
    for (let j = 0; j < 100; j++) {
        const x = (i - 2) * 5;
        const y = 0;
        const z = j * 2 - 100;
        points.push(new THREE.Vector3(x, y, z));
    }

    geometry.setFromPoints(points);
    const line = new THREE.Line(geometry, material);
    scene.add(line);
    trackLines.push(line);
}

// Create particle speed lines
const particlesGeometry = new THREE.BufferGeometry();
const particlesCount = 2000;
const posArray = new Float32Array(particlesCount * 3);
const velocities = new Float32Array(particlesCount);

for (let i = 0; i < particlesCount; i++) {
    posArray[i * 3] = (Math.random() - 0.5) * 100;
    posArray[i * 3 + 1] = (Math.random() - 0.5) * 50;
    posArray[i * 3 + 2] = Math.random() * 100 - 50;
    velocities[i] = Math.random() * 0.5 + 0.2;
}

particlesGeometry.setAttribute('position', new THREE.BufferAttribute(posArray, 3));
const particlesMaterial = new THREE.PointsMaterial({
    size: 0.1,
    color: 0x00ff88,
    transparent: true,
    opacity: 0.6,
    blending: THREE.AdditiveBlending
});
const particlesMesh = new THREE.Points(particlesGeometry, particlesMaterial);
scene.add(particlesMesh);

// Create glowing rings (like speed boosts)
const rings = [];
for (let i = 0; i < 3; i++) {
    const ringGeometry = new THREE.TorusGeometry(3, 0.1, 16, 100);
    const ringMaterial = new THREE.MeshBasicMaterial({
        color: 0x00ff88,
        transparent: true,
        opacity: 0.3
    });
    const ring = new THREE.Mesh(ringGeometry, ringMaterial);
    ring.rotation.x = Math.PI / 2;
    ring.position.z = -20 - i * 20;
    ring.position.y = 0;
    scene.add(ring);
    rings.push(ring);
}

// Mouse interaction
let mouseX = 0;
let mouseY = 0;
let targetRotationY = 0;
let targetRotationX = 0;

document.addEventListener('mousemove', (event) => {
    mouseX = (event.clientX / window.innerWidth) * 2 - 1;
    mouseY = -(event.clientY / window.innerHeight) * 2 + 1;
    targetRotationY = mouseX * 0.3;
    targetRotationX = mouseY * 0.2;
});

// Animation loop with racing effects
let animationSpeed = 0.5;

function animate() {
    requestAnimationFrame(animate);

    // Smooth camera rotation based on mouse
    camera.rotation.y += (targetRotationY - camera.rotation.y) * 0.05;
    camera.rotation.x += (targetRotationX - camera.rotation.x) * 0.05;

    // Animate particles moving forward (speed effect)
    const positions = particlesGeometry.attributes.position.array;
    for (let i = 0; i < particlesCount; i++) {
        positions[i * 3 + 2] += velocities[i] * animationSpeed;

        // Reset particle position when it goes too far
        if (positions[i * 3 + 2] > 50) {
            positions[i * 3 + 2] = -50;
        }
    }
    particlesGeometry.attributes.position.needsUpdate = true;

    // Animate track lines moving
    trackLines.forEach(line => {
        line.position.z += animationSpeed;
        if (line.position.z > 50) {
            line.position.z = -50;
        }
    });

    // Animate rings
    rings.forEach(ring => {
        ring.position.z += animationSpeed;
        ring.rotation.z += 0.01;

        if (ring.position.z > 30) {
            ring.position.z = -60;
        }

        // Pulse effect
        const scale = 1 + Math.sin(Date.now() * 0.002 + ring.position.z) * 0.2;
        ring.scale.set(scale, scale, scale);
    });

    // Animate lights
    const time = Date.now() * 0.001;
    pointLight1.position.x = Math.sin(time * 0.5) * 15;
    pointLight1.position.z = Math.cos(time * 0.5) * 15;

    pointLight2.position.x = Math.sin(time * 0.3 + Math.PI) * 15;
    pointLight2.position.z = Math.cos(time * 0.3 + Math.PI) * 15;

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

    // Increase animation speed based on scroll
    const scrollPercent = window.scrollY / (document.documentElement.scrollHeight - window.innerHeight);
    animationSpeed = 0.5 + scrollPercent * 2;
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
            // Close mobile menu if open
            navLinks.classList.remove('active');
        }
    });
});

// ===== YOUTUBE VIDEO INTEGRATION =====
const YOUTUBE_CHANNEL_ID = 'UCyour_channel_id_here'; // You'll need to get this
const YOUTUBE_API_KEY = 'your_api_key_here'; // You'll need to get this from Google Cloud Console

// For now, we'll show placeholder videos
// To get real videos, you'll need to:
// 1. Go to https://console.cloud.google.com/
// 2. Create a project and enable YouTube Data API v3
// 3. Get your API key
// 4. Get your channel ID from your YouTube channel URL

function loadYouTubeVideos() {
    const videosGrid = document.getElementById('videosGrid');

    // Placeholder videos - replace with actual API call
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

    /*
    // Uncomment and configure this when you have API credentials:

    fetch(`https://www.googleapis.com/youtube/v3/search?key=${YOUTUBE_API_KEY}&channelId=${YOUTUBE_CHANNEL_ID}&part=snippet,id&order=date&maxResults=6`)
        .then(response => response.json())
        .then(data => {
            if (data.items) {
                videosGrid.innerHTML = data.items.map(item => {
                    if (item.id.videoId) {
                        return `
                            <a href="https://youtube.com/watch?v=${item.id.videoId}" target="_blank" class="video-card">
                                <div class="video-thumbnail">
                                    <img src="${item.snippet.thumbnails.medium.url}" alt="${item.snippet.title}">
                                </div>
                                <div class="video-info">
                                    <h3 class="video-title">${item.snippet.title}</h3>
                                    <p class="video-meta">${new Date(item.snippet.publishedAt).toLocaleDateString()}</p>
                                </div>
                            </a>
                        `;
                    }
                    return '';
                }).join('');
            }
        })
        .catch(error => {
            console.error('Error loading videos:', error);
            videosGrid.innerHTML = '<p class="video-placeholder">Unable to load videos. Visit <a href="https://youtube.com/@SparksTheory" target="_blank">my YouTube channel</a> directly.</p>';
        });
    */
}

// Load videos when page loads
document.addEventListener('DOMContentLoaded', loadYouTubeVideos);

// ===== GT7 DRIVER RATING CHECKER =====
const checkDriverBtn = document.getElementById('checkDriver');
const driverInput = document.getElementById('driverInput');
const checkerResults = document.getElementById('checkerResults');

checkDriverBtn?.addEventListener('click', () => {
    const driverId = driverInput.value.trim();

    if (!driverId) {
        checkerResults.innerHTML = '<p style="color: var(--color-accent);">Please enter a PSN ID</p>';
        return;
    }

    checkerResults.innerHTML = '<p>Searching...</p>';

    // Note: Gran Turismo 7 doesn't have an official public API
    // This is a placeholder for future integration or manual stats
    setTimeout(() => {
        checkerResults.innerHTML = `
            <div style="text-align: left;">
                <h3 style="color: var(--color-primary); margin-bottom: 1.5rem;">Driver Profile</h3>
                <div style="display: grid; gap: 1rem;">
                    <div style="display: flex; justify-content: space-between; padding: 0.5rem 0; border-bottom: 1px solid rgba(255,255,255,0.1);">
                        <span style="color: var(--color-text-muted);">PSN ID:</span>
                        <span style="font-weight: 600;">${driverId}</span>
                    </div>
                    <div style="display: flex; justify-content: space-between; padding: 0.5rem 0; border-bottom: 1px solid rgba(255,255,255,0.1);">
                        <span style="color: var(--color-text-muted);">Driver Rating:</span>
                        <span style="font-weight: 600; color: var(--color-primary);">A</span>
                    </div>
                    <div style="display: flex; justify-content: space-between; padding: 0.5rem 0; border-bottom: 1px solid rgba(255,255,255,0.1);">
                        <span style="color: var(--color-text-muted);">Sportsmanship:</span>
                        <span style="font-weight: 600; color: var(--color-secondary);">S</span>
                    </div>
                    <div style="display: flex; justify-content: space-between; padding: 0.5rem 0;">
                        <span style="color: var(--color-text-muted);">Total Races:</span>
                        <span style="font-weight: 600;">142</span>
                    </div>
                </div>
                <p style="margin-top: 1.5rem; color: var(--color-text-muted); font-size: 0.85rem; font-style: italic;">
                    Note: GT7 stats are manually updated. For real-time stats, check your in-game profile.
                </p>
            </div>
        `;
    }, 1000);

    /*
    // Future: If GT7 API becomes available or using a third-party tracker:

    fetch(`https://api.example.com/gt7/driver/${driverId}`)
        .then(response => response.json())
        .then(data => {
            checkerResults.innerHTML = // ... render real data
        })
        .catch(error => {
            checkerResults.innerHTML = '<p style="color: var(--color-accent);">Driver not found or API unavailable</p>';
        });
    */
});

// ===== CONTACT FORM =====
const contactForm = document.getElementById('contactForm');

contactForm?.addEventListener('submit', (e) => {
    e.preventDefault();

    const formData = new FormData(contactForm);
    const submitBtn = contactForm.querySelector('button[type="submit"]');
    const originalText = submitBtn.textContent;

    submitBtn.textContent = 'Sending...';
    submitBtn.disabled = true;

    // Simulate form submission
    // Replace this with your actual form handling (e.g., FormSpree, Netlify Forms, or your backend)
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

    /*
    // Example with FormSpree or similar service:

    fetch('https://formspree.io/f/your_form_id', {
        method: 'POST',
        body: formData,
        headers: {
            'Accept': 'application/json'
        }
    })
    .then(response => {
        if (response.ok) {
            submitBtn.textContent = 'Message Sent!';
            contactForm.reset();
        } else {
            submitBtn.textContent = 'Error - Try Again';
        }
    })
    .catch(error => {
        submitBtn.textContent = 'Error - Try Again';
    })
    .finally(() => {
        setTimeout(() => {
            submitBtn.textContent = originalText;
            submitBtn.disabled = false;
        }, 3000);
    });
    */
});

// ===== SCROLL ANIMATIONS =====
// Add fade-in animations for sections as they come into view
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

// Observe all sections
document.querySelectorAll('.section').forEach(section => {
    section.style.opacity = '0';
    section.style.transform = 'translateY(30px)';
    section.style.transition = 'opacity 0.8s ease, transform 0.8s ease';
    observer.observe(section);
});

// ===== CONSOLE WELCOME MESSAGE =====
console.log('%cSPARKSTHEORY', 'color: #00ff88; font-size: 48px; font-weight: bold; font-family: Rajdhani, sans-serif;');
console.log('%c🏎️ Welcome to the sparkstheory racing website!', 'color: #0ea5e9; font-size: 16px;');
console.log('%cBuilt with Three.js, love, and lots of virtual racing', 'color: #94a3b8; font-size: 12px;');

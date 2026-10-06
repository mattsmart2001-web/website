/* GTEC web push subscribe/unsubscribe helper.
   Depends on the service worker already registered by gtec-nav.js at
   /endurance/sw.js, and on window.GTEC_CONFIG.vapidPublicKey.

   Exposes window.gtecPush = {
       isSupported(), getSubscription(),
       subscribe(sb, driverId), unsubscribe(sb),
   } */
(function () {
    'use strict';

    function urlBase64ToUint8Array(base64String) {
        const padding = '='.repeat((4 - base64String.length % 4) % 4);
        const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
        const rawData = atob(base64);
        const outputArray = new Uint8Array(rawData.length);
        for (let i = 0; i < rawData.length; i++) outputArray[i] = rawData.charCodeAt(i);
        return outputArray;
    }

    window.gtecPush = {
        isSupported() {
            return 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
        },

        async getSubscription() {
            if (!this.isSupported()) return null;
            const reg = await navigator.serviceWorker.ready;
            return reg.pushManager.getSubscription();
        },

        async subscribe(sb, driverId) {
            if (!this.isSupported()) throw new Error('Push notifications aren\'t supported in this browser.');
            const permission = await Notification.requestPermission();
            if (permission !== 'granted') throw new Error('Notification permission was denied.');

            const reg = await navigator.serviceWorker.ready;
            let sub = await reg.pushManager.getSubscription();
            if (!sub) {
                sub = await reg.pushManager.subscribe({
                    userVisibleOnly: true,
                    applicationServerKey: urlBase64ToUint8Array(window.GTEC_CONFIG.vapidPublicKey),
                });
            }

            const json = sub.toJSON();
            const { error } = await sb.from('push_subscriptions').upsert({
                driver_id: driverId,
                endpoint:  json.endpoint,
                p256dh:    json.keys.p256dh,
                auth:      json.keys.auth,
            }, { onConflict: 'endpoint' });
            if (error) throw error;
            return sub;
        },

        async unsubscribe(sb) {
            const sub = await this.getSubscription();
            if (!sub) return;
            await sb.from('push_subscriptions').delete().eq('endpoint', sub.endpoint);
            await sub.unsubscribe();
        },
    };
})();

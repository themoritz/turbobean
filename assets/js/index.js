(function() {
    let eventSource = null;

    function closeExistingConnection() {
        if (eventSource) {
            eventSource.close();
            eventSource = null;
        }
    }

    function establishSSEConnection(account, updateUrl = true) {
        closeExistingConnection();

        if (updateUrl) {
            const url = new URL(window.location);
            url.pathname = '/journal';
            url.search = `account=${encodeURIComponent(account)}`;
            history.pushState({ account: account }, '', url);
        }

        eventSource = new EventSource(`/sse/journal?account=${encodeURIComponent(account)}`);

        eventSource.onmessage = function(event) {
            const contentElement = document.querySelector('content');
            if (contentElement) {
                contentElement.innerHTML = event.data;
            }
        };

        eventSource.onerror = function(event) {
            console.error('SSE connection error:', event);
            closeExistingConnection();
        };
    }

    function getAccountFromUrl() {
        const url = new URL(window.location);
        if (url.pathname === '/journal') {
            return url.searchParams.get('account');
        }
        return null;
    }

    function initializeFromUrl() {
        const account = getAccountFromUrl();
        if (account) {
            const accountInput = document.querySelector('nav form input[name="account"]');
            if (accountInput) {
                accountInput.value = account;
            }
            establishSSEConnection(account, false);
        }
    }

    document.addEventListener('DOMContentLoaded', function() {
        const form = document.querySelector('nav form');
        const accountInput = form.querySelector('input[name="account"]');
        const goButton = form.querySelector('button');

        // Initialize from URL on page load
        initializeFromUrl();

        goButton.addEventListener('click', function(event) {
            event.preventDefault();

            const accountValue = accountInput.value.trim();
            if (accountValue) {
                establishSSEConnection(accountValue);
            }
        });

        // Handle browser back/forward navigation
        window.addEventListener('popstate', function(event) {
            if (event.state && event.state.account) {
                accountInput.value = event.state.account;
                establishSSEConnection(event.state.account, false);
            } else {
                closeExistingConnection();
                accountInput.value = '';
                const contentElement = document.querySelector('content');
                if (contentElement) {
                    contentElement.innerHTML = 'Content';
                }
            }
        });

        // Clean up on page unload
        window.addEventListener('beforeunload', function() {
            closeExistingConnection();
        });
    });

    document.addEventListener('alpine:init', function() {
        Alpine.store('txOpen', {
            open: localStorage.getItem('txOpen') ? JSON.parse(localStorage.getItem('txOpen')) : {},
            toggle(index) {
                if (this.open[index] === undefined) {
                    this.open[index] = false;
                }
                this.open[index] = !this.open[index];
                localStorage.setItem('txOpen', JSON.stringify(this.open));
            }
        });
    });
})();

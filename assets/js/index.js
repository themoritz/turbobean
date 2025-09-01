document.addEventListener('alpine:init', () => {
    Alpine.data('app', () => ({
        account: '',
        startDate: '',
        endDate: '',
        eventSource: null,
        plotData: [],

        init() {
            this.initializeFromUrl();
            this.setupPopstateHandler();
            this.setupBeforeUnloadHandler();
        },

        closeExistingConnection() {
            if (this.eventSource) {
                this.eventSource.close();
                this.eventSource = null;
            }
        },

        establishSSEConnection(account, updateUrl = true) {
            this.closeExistingConnection();

            if (updateUrl) {
                const url = new URL(window.location);
                url.pathname = '/journal';
                const params = new URLSearchParams();
                params.set('account', account);
                if (this.startDate) params.set('startDate', this.startDate);
                if (this.endDate) params.set('endDate', this.endDate);
                url.search = params.toString();
                history.pushState({ account: account, startDate: this.startDate, endDate: this.endDate }, '', url);
            }

            const params = new URLSearchParams();
            params.set('account', account);
            if (this.startDate) params.set('startDate', this.startDate);
            if (this.endDate) params.set('endDate', this.endDate);
            this.eventSource = new EventSource(`/sse/journal?${params.toString()}`);

            this.eventSource.onmessage = (event) => {
                const contentElement = this.$refs.content;
                if (contentElement) {
                    const journal = contentElement.querySelector('.journal');
                    const scrollPos = journal ? journal.scrollTop : 0;
                    contentElement.innerHTML = event.data;
                    const newJournal = contentElement.querySelector('.journal');
                    if (newJournal) {
                        newJournal.scrollTop = scrollPos;
                    }
                }
            };

            this.eventSource.addEventListener('plot_points', (event) => {
                this.plotData = JSON.parse(event.data);
            })

            this.eventSource.onerror = (event) => {
                console.error('SSE connection error:', event);
                this.closeExistingConnection();
            };
        },

        getAccountFromUrl() {
            const url = new URL(window.location);
            if (url.pathname === '/journal') {
                return {
                    account: url.searchParams.get('account'),
                    startDate: url.searchParams.get('startDate') || '',
                    endDate: url.searchParams.get('endDate') || ''
                };
            }
            return null;
        },

        initializeFromUrl() {
            const urlParams = this.getAccountFromUrl();
            if (urlParams && urlParams.account) {
                this.account = urlParams.account;
                this.startDate = urlParams.startDate;
                this.endDate = urlParams.endDate;
                this.establishSSEConnection(urlParams.account, false);
            }
        },

        handleFormSubmit() {
            const accountValue = this.account.trim();
            if (accountValue) {
                this.establishSSEConnection(accountValue);
            }
        },

        setupPopstateHandler() {
            window.addEventListener('popstate', (event) => {
                if (event.state && event.state.account) {
                    this.account = event.state.account;
                    this.startDate = event.state.startDate || '';
                    this.endDate = event.state.endDate || '';
                    this.establishSSEConnection(event.state.account, false);
                } else {
                    this.closeExistingConnection();
                    this.account = '';
                    this.startDate = '';
                    this.endDate = '';
                    this.content = 'Content';
                }
            });
        },

        setupBeforeUnloadHandler() {
            window.addEventListener('beforeunload', () => {
                this.closeExistingConnection();
            });
        }
    }));

    Alpine.data('d3', () => {
        const margin = {
            top: 20,
            right: 30,
            bottom: 50,
            left: 50
        };

        const svg = d3.select("#d3 svg");
        const tooltip = d3.select("#d3 .tooltip");

        const xGroup = svg.append("g");
        const yGroup = svg.append("g").attr("class", "mono");

        // Grid lines group
        const grid = svg.append("g").attr("class", "grid");
        const hLine = grid
            .append("line")
            .attr("stroke", "hsl(0deg 0% 70% / 0.8)")
            .attr("stroke-width", "0.5")
            .style("display", "none");
        const vLine = grid
            .append("line")
            .attr("stroke", "hsl(0deg 0% 70% / 0.8)")
            .attr("stroke-width", "0.5")
            .style("display", "none");

        return {

            init() {
                this.$watch('plotData', (newData) => {
                    if (newData && newData.length > 0) {
                        this.updateChart(newData);
                    }
                });
            },

            updateChart(alpineData) {

                const data = [];

                alpineData.forEach((txn) => {
                    data.push({
                        hash: txn.hash,
                        date: new Date(txn.date),
                        balance: txn.balance,
                        balance_rendered: txn.balance_rendered,
                        currency: txn.currency,
                    })
                });

                const width = document.querySelector("#d3 svg").clientWidth;
                const height = width / 5;

                svg.attr("viewBox", `${-margin.left} ${-margin.top} ${width + margin.left + margin.right} ${height + margin.top + margin.bottom}`);

                xGroup.attr("transform", `translate(0,${height})`);

                const x = d3
                    .scaleUtc()
                    .domain(d3.extent(data, (txn) => txn.date))
                    .nice()
                    .range([0, width]);

                const y = d3
                    .scaleLinear()
                    .domain(d3.extent(data, (txn) => txn.balance))
                    .nice()
                    .range([height, 0]);


                const t = d3.transition().duration(300);

                // Horizontal segments (solid)
                svg
                    .selectAll(".horizontal")
                    .data(data.slice(0, -1), (d) => d.hash) // One less than points
                    .join(
                        enter => enter
                            .append("line")
                            .attr("class", "horizontal")
                            .attr("stroke", "black")
                            .attr("stroke-width", 1)
                            .attr("x1", (d, _) => x(d.date))
                            .attr("y1", (d, _) => y(d.balance))
                            .attr("x2", (_, i) => x(data[i + 1].date)) // Next x
                            .attr("y2", (d, _) => y(d.balance))
                            .style("opacity", 0)
                            .transition(t)
                            .style("opacity", 1),
                        update => update
                            .transition(t)
                            .attr("x1", (d, _) => x(d.date))
                            .attr("y1", (d, _) => y(d.balance))
                            .attr("x2", (_, i) => x(data[i + 1].date)) // Next x
                            .attr("y2", (d, _) => y(d.balance)),
                        exit => exit
                            .transition(t)
                            .style("opacity", 0)
                            .remove(),
                    );

                // Vertical segments (dashed)
                svg
                    .selectAll(".vertical")
                    .data(data.slice(1), (d) => d.hash) // From second point onward
                    .join(
                        enter => enter
                            .append("line")
                            .attr("class", "vertical")
                            .attr("stroke", "hsl(0deg 0% 80%")
                            .attr("stroke-width", 1)
                            .attr("stroke-dasharray", "5,5")
                            .attr("x1", (d, _) => x(d.date))
                            .attr("y1", (_, i) => y(data[i].balance)) // Previous y
                            .attr("x2", (d, _) => x(d.date))
                            .attr("y2", (d, _) => y(d.balance))
                            .style("opacity", 0)
                            .transition(t)
                            .style("opacity", 1),
                        update => update
                            .transition(t)
                            .attr("x1", (d, _) => x(d.date))
                            .attr("y1", (_, i) => y(data[i].balance)) // Previous y
                            .attr("x2", (d, _) => x(d.date))
                            .attr("y2", (d, _) => y(d.balance)),
                        exit => exit
                            .transition(t)
                            .style("opacity", 0)
                            .remove(),
                    );

                // Circles at each point
                const circles = svg
                    .selectAll("circle")
                    .data(data, (d) => d.hash)
                    .join(
                        enter => enter
                            .append("circle")
                            .attr("stroke", "black")
                            .attr("stroke-width", 1)
                            .attr("fill", "white")
                            .attr("r", 2)
                            .attr("cx", (d) => x(d.date))
                            .attr("cy", (d) => y(d.balance))
                            .style("opacity", 0)
                            .transition(t)
                            .style("opacity", 1),
                        update => update
                            .transition(t)
                            .attr("cx", (d) => x(d.date))
                            .attr("cy", (d) => y(d.balance)),
                        exit => exit
                            .transition(t)
                            .style("opacity", 0)
                            .remove()
                    );

                xGroup
                    .transition(t)
                    .call(d3.axisBottom(x));

                yGroup.transition(t)
                    .call(d3.axisLeft(y).tickFormat(d3.format("~s")));

                // Invisible rectangle for mouse events
                svg
                    .append("rect")
                    .attr("width", width)
                    .attr("height", height)
                    .attr("fill", "none")
                    .attr("pointer-events", "all")
                    .on("mousemove", function(event) {
                        // Get mouse position relative to SVG
                        const [mx, my] = d3.pointer(event, svg.node());

                        // Find closest point
                        let closest = null;
                        let closestIndex = -1;
                        let minDist = Infinity;
                        data.forEach((d, i) => {
                            const px = x(d.date);
                            const py = y(d.balance);
                            const dist = Math.sqrt((mx - px) ** 2 + (my - py) ** 2);
                            if (dist < minDist) {
                                minDist = dist;
                                closest = d;
                                closestIndex = i;
                            }
                        });

                        circles.attr("fill", "white");

                        if (minDist <= 20) {
                            const px = x(closest.date);
                            const py = y(closest.balance);
                            circles.filter((_, i) => i === closestIndex).attr("fill", "black");

                            tooltip
                                .style("display", "block")
                                .style("left", `${event.pageX + 10}px`)
                                .style("top", `${event.pageY - 10}px`)
                                .text(`${closest.date.toISOString().split('T')[0]}: ${closest.balance_rendered} ${closest.currency}`);

                            hLine
                                .style("display", "block")
                                .attr("x1", 0)
                                .attr("y1", py)
                                .attr("x2", Math.max(0, px - 10))
                                .attr("y2", py);
                            vLine
                                .style("display", "block")
                                .attr("x1", px)
                                .attr("y1", height)
                                .attr("x2", px)
                                .attr("y2", Math.min(py + 10, height));
                        } else {
                            // Hide tooltip and lines
                            tooltip.style("display", "none");
                            hLine.style("display", "none");
                            vLine.style("display", "none");
                        }
                    })
                    .on("mouseleave", () => {
                        tooltip.style("display", "none");
                        hLine.style("display", "none");
                        vLine.style("display", "none");
                        circles.attr("fill", "white");
                    });
            }
        }
    });

    Alpine.store('txOpen', {
        open: localStorage.getItem('txOpen') ? JSON.parse(localStorage.getItem('txOpen')) : {},
        toggle(index) {
            if (this.open[index] === undefined) {
                this.open[index] = false;
            }
            this.open[index] = !this.open[index];
            if (!this.open[index]) {
                delete this.open[index];
            }
            localStorage.setItem('txOpen', JSON.stringify(this.open));
        }
    });
});

return {
    instant = {
        maxMessagesPerTick = math.huge,
        maxBytesPerTick = math.huge,
        jitterTicks = 0,
        dropRate = 0,
        reorder = false,
        competingTrafficBytesPerTick = 0,
    },

    throttled = {
        maxMessagesPerTick = 3,
        maxBytesPerTick = 4096,
        jitterTicks = 2,
        dropRate = 0,
        reorder = true,
        competingTrafficBytesPerTick = 1024,
    },

    saturated = {
        maxMessagesPerTick = 1,
        maxBytesPerTick = 2048,
        jitterTicks = 5,
        dropRate = 0.02,
        reorder = true,
        competingTrafficBytesPerTick = 4096,
    },

    loginBurst = {
        maxMessagesPerTick = 5,
        maxBytesPerTick = 8192,
        jitterTicks = 3,
        dropRate = 0,
        reorder = true,
        competingTrafficBytesPerTick = 2048,
        burstPeers = true,
    },
}

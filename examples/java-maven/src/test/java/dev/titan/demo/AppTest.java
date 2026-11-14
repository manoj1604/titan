package dev.titan.demo;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class AppTest {
    @Test
    void runsOnLinux() {
        assertEquals("Linux aarch64", App.platform());
    }
}

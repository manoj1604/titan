package dev.titan.demo;

public class App {
    public static String platform() {
        return System.getProperty("os.name") + " " + System.getProperty("os.arch");
    }

    public static void main(String[] args) {
        System.out.println("{\"ok\":true,\"platform\":\"" + platform() + "\",\"java\":\"" + Runtime.version() + "\"}");
    }
}

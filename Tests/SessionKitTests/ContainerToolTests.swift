import Testing
import TetherCore

/// Container tools in a terminal are told apart, and what they do is read from their command line.
@Suite struct ContainerToolTests {
    @Test func kinds() {
        #expect(ToolKind(program: "docker") == .docker)
        #expect(ToolKind(program: "/usr/local/bin/docker", commandLine: "docker compose up") == .compose)
        #expect(ToolKind(program: "docker", commandLine: "docker --context prod compose -f stack.yml up -d") == .compose)
        #expect(ToolKind(program: "docker-compose") == .compose)
        #expect(ToolKind(program: "podman", commandLine: "podman run -it alpine sh") == .podman)
        #expect(ToolKind(program: "podman", commandLine: "podman compose up") == .compose)
        #expect(ToolKind(program: "dockerd") == nil)
        #expect(ToolKind(program: "vim") == nil)
    }

    @Test func whatTheyDo() {
        #expect(ToolKind.doing("docker build -t app .") == "building an image")
        #expect(ToolKind.doing("docker buildx build --platform linux/amd64 .") == "building an image")
        #expect(ToolKind.doing("docker run -it --rm ubuntu bash") == "running a container")
        #expect(ToolKind.doing("docker run -d nginx") == "starting a container")
        #expect(ToolKind.doing("docker exec -it web sh") == "inside a container")
        #expect(ToolKind.doing("docker logs -f web") == "following a container's logs")
        #expect(ToolKind.doing("docker compose up") == "running services")
        #expect(ToolKind.doing("docker compose -f prod.yml up -d") == "starting services")
        #expect(ToolKind.doing("docker-compose logs --follow api") == "following the services' logs")
        #expect(ToolKind.doing("docker -H tcp://192.0.2.10:2376 pull redis") == "pulling an image")
        #expect(ToolKind.doing("docker system prune -a") == "cleaning up")
        #expect(ToolKind.doing("docker version") == nil)
        #expect(ToolKind.doing("docker") == nil)
        #expect(ToolKind.doing(nil) == nil)
    }
}
